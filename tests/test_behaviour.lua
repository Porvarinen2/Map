-- Stress, morale, fatigue and personality must each change what NPCs do.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Population = require("sim.population")
local Director = require("sim.director")
local Behaviour = require("sim.behaviour")
local Stress = require("npc.stress")
local POI = require("world.pois")
local Bridge = require("mock_bridge")

Log.configure(nil, "error", false)

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end
local function section(t) print("\n== " .. t .. " ==") end

local events = {}
local orig_event = Log.event
Log.event = function(kind, subject, detail)
    events[#events + 1] = { kind = kind, subject = subject, detail = detail }
    return orig_event(kind, subject, detail)
end
local function count(kind, gid)
    local n = 0
    for _, e in ipairs(events) do
        if e.kind == kind and (not gid or e.subject == gid) then n = n + 1 end
    end
    return n
end

local function fresh(seed)
    Bridge.reset()
    Bridge.zombies = {}
    Bridge.configure(RNG.new(seed), { spawn_fail_rate = 0, move_reject_rate = 0 })
    local world = Population.new_world({ seed = seed, target_npcs = 40 })
    Population.generate(world)
    local d = Director.new({ world = world, bridge = Bridge, seed = seed,
        config = { RouteSolvesPerTick = 3, RouteExpansionsPerTick = 7000 } })
    return world, d
end

local function avg_stress(g)
    local s, n = 0, 0
    for _, m in ipairs(g.members) do if m.alive then s = s + (m.stress or 0); n = n + 1 end end
    return n > 0 and s / n or 0
end

local function first_group(world, pred)
    for _, g in ipairs(world.groups) do
        if g.class ~= "radiation_group" and Population.group_alive(g) and #g.members >= 2
            and (not pred or pred(g)) then return g end
    end
end

-- -------------------------------------------------------------------------
section("personality changes the same shock")
do
    local brave = { traits = { stressResistance = 0.9, composure = 0.9, fearfulness = 0.1 }, stress = 0, morale = 0.7 }
    local timid = { traits = { stressResistance = 0.1, composure = 0.2, fearfulness = 0.9 }, stress = 0, morale = 0.7 }
    Stress.apply(brave, "GUNSHOT_NEAR")
    Stress.apply(timid, "GUNSHOT_NEAR")
    check(timid.stress > brave.stress * 2, string.format(
        "a fearful NPC takes gunfire far harder (%.2f vs %.2f)", timid.stress, brave.stress))
    check(timid.morale < brave.morale, "and loses more morale")
end

section("stress, fatigue and wounds ruin aim")
do
    local calm = { stress = 0.1, traits = {}, health = 100 }
    local scared = { stress = 0.9, traits = {}, health = 100 }
    local a1, a2 = Behaviour.accuracy(calm, 10), Behaviour.accuracy(scared, 10)
    check(a2 < a1 * 0.6, string.format("a panicking shooter hits far less (%.2f vs %.2f)", a2, a1))
    check(Behaviour.accuracy(calm, 95) < a1 * 0.8, "an exhausted shooter hits less")
    local hurt = { stress = 0.1, traits = {}, health = 30 }
    check(Behaviour.accuracy(hurt, 10) < a1, "a badly wounded shooter hits less")
end

section("background decides how hard and how long")
do
    local function npc(arch, lvl) return { archetype = arch, level = lvl, alive = true,
        traits = {}, stress = 0, morale = 0.7 } end
    local surv, vet = npc("survivor", 2), npc("veteran", 4)
    Stress.apply(surv, "GUNSHOT_NEAR"); Stress.apply(vet, "GUNSHOT_NEAR")
    check(surv.stress > vet.stress * 2, string.format(
        "a survivor takes gunfire much harder than a veteran (%.2f vs %.2f)", surv.stress, vet.stress))
    surv.stress, vet.stress = 0.8, 0.8
    for _ = 1, 300 do Stress.recover(surv, 1, false); Stress.recover(vet, 1, false) end
    local ds, dv = 0.8 - surv.stress, 0.8 - vet.stress
    check(ds > 0.002 and ds < 0.02, string.format(
        "a survivor sheds about one point in five minutes (%.3f)", ds))
    check(dv > ds * 2, string.format("a veteran recovers much faster (%.3f vs %.3f)", dv, ds))
    local d0 = npc("survivor", 2); d0.stress = 0.8
    for _ = 1, 300 do Stress.recover(d0, 1, true) end
    check(0.8 - d0.stress < ds * 0.5, "in danger hardly anyone recovers")
end

section("losing the other half of a pair")
do
    local Combat = require("sim.combat")
    local rng = RNG.new(3)
    local a = { name = "A", alive = true, stress = 0.1, morale = 0.7, archetype = "survivor",
                level = 2, traits = { aggression = 0.3, fearfulness = 0.7 } }
    local b = { name = "B", alive = true, stress = 0.1, morale = 0.7, archetype = "survivor",
                level = 2, traits = {} }
    local pair = { gid = "PAIR", members = { a, b }, morale = 0.7, cohesion = 0.8 }
    Combat.on_member_lost(pair, b, rng, nil, nil, nil)
    check(a.stress >= 0.85, string.format("the survivor is shattered (stress %.2f)", a.stress))
    check(a.traumas and a.traumas.FEAR_OF_LOSS, "and carries the fear of loss")
    local n = 0
    for _ in pairs(a.traumas or {}) do n = n + 1 end
    check(n >= 2, "and a second scar by temperament (" .. n .. " traumas)")
    check(a.grief_until and a.grief_until > os.time() + 3600, "grief lasts for hours")
    check(Stress.baseline(a) >= 0.3, string.format("grief keeps the stress floor high (%.2f)", Stress.baseline(a)))
    check(a.shock_until and a.shock_until > os.time(), "first comes shock")
    local trio = { gid = "T", members = {}, morale = 0.7, cohesion = 0.8 }
    for i = 1, 3 do trio.members[i] = { name = "T" .. i, alive = true, stress = 0.1, morale = 0.7,
        archetype = "survivor", level = 2, traits = {} } end
    Combat.on_member_lost(trio, trio.members[3], rng, nil, nil, nil)
    check(trio.members[1].stress < a.stress, "losing one of three hurts, losing your only partner hurts most")
end

-- -------------------------------------------------------------------------
section("zombies around a physical squad")
do
    local world, d = fresh(11)
    local g = first_group(world)
    local sim = os.time()
    local function run(n)
        for _ = 1, n do
            sim = sim + 1
            Bridge.players = { { X = g.position.X + 3000, Y = g.position.Y, Z = 0 } }
            Bridge.step(1)
            d:tick(sim)
        end
    end
    run(15)
    check(g.physical, "the squad is physical")
    local before = avg_stress(g)
    -- Six zombies 25 m away.
    for i = 1, 6 do
        Bridge.zombies[#Bridge.zombies + 1] = {
            pos = { X = g.position.X + 2500 + i * 60, Y = g.position.Y + i * 40, Z = 0 },
            actor = { hp = 100 } }
    end
    local moods = {}
    for _ = 1, 30 do
        run(1)
        moods[g.mood or "?"] = true
    end
    local after = avg_stress(g)
    check(after > before + 0.1, string.format("zombies raise stress (%.2f -> %.2f)", before, after))
    check(moods.ZOMBIES or moods.PANIC, "the squad fights the zombies or panics")
    check(Bridge.zombie_damage > 0, string.format("zombies get shot (%d hits)", Bridge.zombie_damage))
    local killed = 0
    for _, z in ipairs(Bridge.zombies) do if z.actor.hp <= 0 then killed = killed + 1 end end
    check(killed >= 1, string.format("and some go down (%d of 6)", killed))
    -- With the zombies gone the squad calms down again.
    Bridge.zombies = {}
    local peak = avg_stress(g)
    run(1800)
    check(avg_stress(g) < peak, string.format(
        "stress falls again once it is quiet, slowly (%.2f -> %.2f in 30 min)", peak, avg_stress(g)))
end

-- -------------------------------------------------------------------------
section("panic makes a squad run")
do
    local world, d = fresh(12)
    local g = first_group(world)
    local sim = os.time()
    local function run(n)
        for _ = 1, n do
            sim = sim + 1
            Bridge.players = { { X = g.position.X + 3000, Y = g.position.Y, Z = 0 } }
            Bridge.step(1)
            d:tick(sim)
        end
    end
    run(15)
    local threat = { X = g.position.X + 2000, Y = g.position.Y, Z = 0 }
    for i = 1, 8 do
        Bridge.zombies[#Bridge.zombies + 1] = { pos = { X = threat.X + i * 30, Y = threat.Y, Z = 0 },
                                                actor = { hp = 100000 } }
    end
    for _, m in ipairs(g.members) do m.stress = 0.95 end
    g.hit_at = sim
    local start = U.dist2d(g.position, threat)
    local panicked = false
    for _ = 1, 25 do
        run(1)
        if g.mood == "PANIC" or g.mood == "ROUT" then panicked = true end
    end
    check(panicked, "a squad deep in fear panics")
    check(count("PANIC", g.gid) >= 1, "the panic is on record")
    local gone = U.dist2d(g.position, threat)
    check(gone > start + 3000, string.format("and runs from the threat (%.0f m -> %.0f m)", start / 100, gone / 100))
end

-- -------------------------------------------------------------------------
section("gunfire heard from afar")
do
    local world, d = fresh(13)
    local g = first_group(world)
    local sim = os.time()
    Bridge.players = {}
    d:tick(sim)
    local before = avg_stress(g)
    local reactions = count("INVESTIGATE", g.gid) + count("AVOID", g.gid) + count("HOLD", g.gid)
    for _ = 1, 40 do
        sim = sim + 1
        -- Someone is shooting 90 m away.
        Behaviour.noise(d, { X = g.position.X + 9000, Y = g.position.Y, Z = 0 }, "gunfire", 1.2)
        d.noises[#d.noises].from = "SOMEONE"
        d:tick(sim)
    end
    check(avg_stress(g) > before + 0.05, string.format("gunfire makes a squad uneasy (%.2f -> %.2f)", before, avg_stress(g)))
    local after = count("INVESTIGATE", g.gid) + count("AVOID", g.gid) + count("HOLD", g.gid)
    check(after > reactions or g.act.state == "TRAVEL",
          "it goes to look, backs off or stops to listen (unless it is on the road)")
end

-- -------------------------------------------------------------------------
section("fear spreads, a steady leader holds it")
do
    local function spread(leader_skill)
        local g = { cohesion = 0.7, morale = 0.6, members = {} }
        for i = 1, 4 do
            g.members[i] = { alive = true, stress = (i == 1) and 0.95 or 0.1, morale = 0.6,
                             traits = { composure = leader_skill }, skills = { leadership = leader_skill },
                             is_leader = (i == 2) }
        end
        for _ = 1, 30 do Behaviour.contagion(g, 1) end
        return g.members[3].stress
    end
    local weak, strong = spread(0.05), spread(0.95)
    check(weak > 0.2, string.format("one panicking member unsettles the rest (%.2f)", weak))
    check(strong < weak, string.format("less so under a steady leader (%.2f vs %.2f)", strong, weak))
end

-- -------------------------------------------------------------------------
section("the undead in the abstract")
do
    local world, d = fresh(14)
    local g = first_group(world)
    local city = nil
    for _, p in ipairs(POI.points) do if p.kind == "CITY" and not p.blocked then city = p; break end end
    g.act.goal_poi = city
    g.act.state = "SEARCH"
    g.act.until_t = os.time() + 100000
    g.position = U.copy_vec(city.pos)
    local sim = os.time()
    local peak = 0
    for _ = 1, 900 do
        sim = sim + 1
        g.act.state = "SEARCH"; g.act.until_t = sim + 100
        d:tick(sim)
        peak = math.max(peak, avg_stress(g))
    end
    check(peak > 0.3, string.format("a squad searching a city runs into zombies (peak stress %.2f)", peak))
end

print("")
os.exit(fails == 0 and 0 or 1)
