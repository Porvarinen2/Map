-- Server lifecycle test.
--
-- Mimics what main.lua actually does: boot a world, run it, save, shut down,
-- start again from the save, and keep running. This is the path that decides
-- whether the world is genuinely persistent across a server restart.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Persist = require("core.persist")
local POI = require("world.pois")
local Population = require("sim.population")
local Director = require("sim.director")
local Telemetry = require("bridge.telemetry")
local Bridge = require("mock_bridge")

Log.configure(nil, "error", false)

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end

local TMP = os.getenv("TMPDIR") or "/tmp"
local dir = TMP .. "/tesles_lifecycle"
os.execute("rm -rf '" .. dir .. "' && mkdir -p '" .. dir .. "'")
Persist.configure(dir, 45)
Telemetry.configure(dir)

local rng = RNG.new(2024)
Bridge.configure(rng, { spawn_fail_rate = 0.05, move_reject_rate = 0.05 })

-- ---------------------------------------------------------- first boot ----

local world = Population.new_world({ seed = 777, target_npcs = 100 })
Population.generate(world)
local before_npcs = Population.alive_npc_count(world)
local before_groups = #world.groups
print(string.format("boot 1: %d groups / %d NPCs", before_groups, before_npcs))

local director = Director.new({ world = world, bridge = Bridge, seed = 1,
    config = { RouteSolvesPerTick = 2, RouteExpansionsPerTick = 7000 } })

local player = { pos = U.copy_vec(POI.points[3].pos) }
local now = os.time()
for i = 1, 2400 do
    now = now + 1
    local goal = POI.points[((i // 600) % POI.count) + 1].pos
    local d = U.direction(player.pos, goal)
    if d then
        player.pos.X = player.pos.X + d.X * 450
        player.pos.Y = player.pos.Y + d.Y * 450
    end
    Bridge.players = { player.pos }
    Bridge.step(1)
    director:tick(now)
end

-- Capture what the world looked like at shutdown. Counts are taken here, not
-- at boot: groups legitimately merge while the world runs.
local at_save_groups = #world.groups
local at_save_npcs = Population.alive_npc_count(world)
local snapshot = {}
for _, g in ipairs(world.groups) do
    snapshot[g.gid] = {
        pos = U.copy_vec(g.position),
        state = g.act.state,
        goal = g.act.goal_poi and g.act.goal_poi.id or nil,
        fatigue = g.act.fatigue,
        leader = g.leader_id,
        members = {},
    }
    for _, m in ipairs(g.members) do
        snapshot[g.gid].members[m.npcId] = {
            alive = m.alive, stress = m.stress, courage = m.traits.courage,
            rifle = m.skills.rifle, archetype = m.archetype, level = m.level,
        }
    end
end

-- Two save cycles, as the running server does every SaveIntervalSec, so the
-- rolling backup is exercised too.
Persist.rotate()
local saved = Persist.save(Population.serialize(world))
check(saved, "world state written to disk")
Persist.rotate()
saved = Persist.save(Population.serialize(world)) and saved
check(saved, "second save cycle rotated the previous file")
local ok_tel = Telemetry.write(world, Bridge, director, { version = "test", uptime = 2400 })
check(ok_tel, "live_state.json written")

-- ------------------------------------------------------------- restart ----

Bridge.reset()
local raw = Persist.load()
check(raw ~= nil, "world state read back from disk")
local world2 = Population.deserialize(raw)
print(string.format("boot 2: %d groups / %d NPCs",
    #world2.groups, Population.alive_npc_count(world2)))

check(#world2.groups == at_save_groups, "every group survived the restart")
check(Population.alive_npc_count(world2) == at_save_npcs, "every NPC survived the restart")
check(at_save_npcs == before_npcs, "no NPC was lost while the world ran")

local drift, bad_person, bad_state = 0, 0, 0
for _, g in ipairs(world2.groups) do
    local was = snapshot[g.gid]
    if not was then bad_state = bad_state + 1
    else
        drift = math.max(drift, U.dist2d(was.pos, g.position))
        if g.leader_id ~= was.leader then bad_state = bad_state + 1 end
        if math.abs((g.act.fatigue or 0) - was.fatigue) > 0.001 then bad_state = bad_state + 1 end
        for _, m in ipairs(g.members) do
            local w = was.members[m.npcId]
            if not w then bad_person = bad_person + 1
            elseif w.alive ~= m.alive
                or math.abs(w.courage - m.traits.courage) > 1e-9
                or math.abs(w.rifle - m.skills.rifle) > 1e-9
                or w.archetype ~= m.archetype or w.level ~= m.level then
                bad_person = bad_person + 1
            end
        end
    end
end
check(drift < 1, string.format("positions restored exactly (%.2f UU drift)", drift))
check(bad_person == 0, string.format("%d personality/identity mismatches", bad_person))
check(bad_state == 0, string.format("%d group-state mismatches", bad_state))

-- The restarted world must keep running, not just load.
local director2 = Director.new({ world = world2, bridge = Bridge, seed = 2,
    config = { RouteSolvesPerTick = 2, RouteExpansionsPerTick = 7000 } })
for i = 1, 900 do
    now = now + 1
    Bridge.players = { player.pos }
    Bridge.step(1)
    director2:tick(now)
end
print(string.format("after restart: routes=%d arrivals=%d commands=%d",
    director2.counters.routes, director2.counters.arrivals, director2.counters.commands))
check(director2.counters.routes > 0, "the restored world plans routes again")

local moved = 0
for _, g in ipairs(world2.groups) do
    local was = snapshot[g.gid]
    if was and U.dist2d(was.pos, g.position) > 20000 then moved = moved + 1 end
end
check(moved >= 5, string.format("%d groups carried on travelling after the restart", moved))

-- A corrupt save must not take the server down with it.
local f = io.open(U.join(dir, "world_state.json"), "w")
f:write('{"groups":[{"broken":')
f:close()
local bad, why = Persist.load()
check(bad == nil and why == "PARSE_ERROR", "a corrupt save is rejected, not crashed on")

local backup = io.open(U.join(dir, "world_state.json.bak"), "r")
check(backup ~= nil, "the previous save is kept as a rolling backup")
if backup then backup:close() end

os.execute("rm -rf '" .. dir .. "'")
os.exit(fails == 0 and 0 or 1)
