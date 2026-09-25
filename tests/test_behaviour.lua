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
        if not require("world.zones").reserved_by_class[g.class] and Population.group_alive(g) and #g.members >= 2
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
    -- Ordinary people, not a hardened unit that shrugs zombies off.
    local HARD = { military_group = true, elite_unit = true, militia_cell = true, bunker_group = true }
    local g = first_group(world, function(x) return not HARD[x.class] end)
    for _, m in ipairs(g.members) do
        m.archetype, m.experience = "survivor", 0
        m.traits.courage, m.traits.stressResistance, m.traits.fearfulness = 0.5, 0.5, 0.5
        m.traits.composure = 0.5
    end
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
            actor = { hp = 400 } }  -- tough enough to stay a while
    end
    local moods = {}
    for _ = 1, 30 do
        -- The zombies follow the squad (a travelling squad would otherwise
        -- just leave them behind).
        for i, z in ipairs(Bridge.zombies) do
            z.pos = { X = g.position.X + 2500 + i * 60, Y = g.position.Y + i * 40, Z = 0 }
        end
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
section("the Z4 island town")
do
    local Zones = require("world.zones")
    local Grid = require("world.navgrid")
    local world, d = fresh(21)
    local isl = Zones.reserved_by_class.island_residents
    local own, inside, others_in = 0, 0, 0
    for _, g in ipairs(world.groups) do
        local here = Zones.in_zone(isl, g.position)
        if g.class == "island_residents" then
            own = own + 1
            if here and Grid.landmass_at(g.position) == isl.landmass then inside = inside + 1 end
        elseif here then others_in = others_in + 1 end
    end
    check(own == 2 and inside == 2, string.format("the island town has its two resident squads, on the island (%d/%d)", inside, own))
    check(others_in == 0, "nobody else lives on the island")
    local sim = os.time()
    local left, visited, crossed = 0, {}, 0
    local mass = {}
    for _, g in ipairs(world.groups) do mass[g] = Grid.landmass_at(g.position) end
    for _ = 1, 1800 do
        sim = sim + 1
        d:tick(sim)
        for _, g in ipairs(world.groups) do
            if g.class == "island_residents" then
                if not Zones.in_zone(isl, g.position) then left = left + 1 end
                if g.act.goal_poi then visited[g.act.goal_poi.id] = true end
            elseif Zones.in_zone(isl, g.position) then others_in = others_in + 1 end
            local m = Grid.landmass_at(g.position)
            if m and mass[g] and m ~= mass[g] then crossed = crossed + 1; mass[g] = m end
        end
    end
    local spots = 0
    for id in pairs(visited) do if id:find("^ISL_Z4_") or id == "VIL_Z4_01" then spots = spots + 1 end end
    check(left == 0 and others_in == 0, "the residents never leave, nobody else comes over")
    check(spots >= 2, string.format("the residents walk the town (%d places)", spots))
    check(crossed == 0, "no squad crosses water to another landmass")
    local Commands = require("sim.commands")
    local n0 = #world.groups
    Commands.run_line(d, "t1 spawn bandit_gang 2 " .. isl.anchor.X .. " " .. isl.anchor.Y)
    Commands.run_line(d, "t2 spawn island_residents 2 0 0")
    check(#world.groups == n0, "the map cannot put other squads on the island, nor residents elsewhere")
end

section("weapons: condition, scopes, reach")
do
    local W = require("npc.weapons")
    local Combat = require("sim.combat")
    local rng = RNG.new(5)
    local function avg_cond(class)
        local sum = 0
        for i = 1, 40 do sum = sum + W.gear_for(class, { level = 3 }, {}, rng).condition end
        return sum / 40
    end
    local e, sc = avg_cond("elite_unit"), avg_cond("scavengers")
    check(e > 0.85 and sc < 0.5, string.format("the elite keep their weapons in shape, scavengers do not (%.0f %% vs %.0f %%)", e * 100, sc * 100))
    local scoped, rifles = 0, 0
    for _ = 1, 200 do
        local g = W.gear_for("hunters", { level = 3 }, {}, rng)
        if #W.scopes_for(g.weapon) > 0 then
            rifles = rifles + 1
            if g.scoped then scoped = scoped + 1 end
        end
    end
    check(rifles > 0 and scoped > rifles * 0.2 and scoped < rifles * 0.6,
          string.format("some hunting rifles carry a scope (%d of %d)", scoped, rifles))
    check(W.profile("Weapon_Hunter85_V2", true).range == 20000 and W.profile("Weapon_Hunter85_V2", true).acc > 1.5
          and W.profile("Weapon_M1911").range == 5000 and W.profile("2H_Axe").range <= 300,
          "a scope reaches 200 m and aims far better; a pistol 50 m, an axe arm's length")
    -- One marksman against a squad 180 m away: only the scope reaches.
    local function duel(scope)
        local a = { members = { { alive = true, level = 3, skills = { rifle = 0.6 }, position = { X = 0, Y = 0 },
                                  gear = { weapon = "Weapon_Hunter85_V2", scoped = scope } } } }
        local b = { members = { { alive = true, health = 100, position = { X = 18000, Y = 0 } } } }
        local shots = 0
        for _ = 1, 60 do shots = shots + (Combat.exchange_fire(a, b, rng).shots or 0) end
        return shots
    end
    check(duel(true) > 0 and duel(false) == 0, "a scoped rifle fires at 180 m, the same rifle without one does not")
    local function has(list, n) for _, x in ipairs(list) do if x == n then return true end end return false end
    local sh = W.similar("Weapon_SDASS", "bandit_gang", { "Weapon_SVD_Dragunov", "Weapon_M1887" })
    check(sh[1] == "Weapon_M1887" and not has(sh, "Weapon_SVD_Dragunov"),
          "a ghost weapon looks like what it fires: a shotgun shows a shotgun, never an SVD")
    check(#W.similar("Weapon_SDASS", "military_group", {}) == 0, "and a squad without shotguns shows SCUM's own")
    local qv = W.similar("Weapon_AS_Val", "military_group", { "Weapon_SCAR_DMR", "Weapon_SVD_Dragunov", "Weapon_VSS_VZ" })
    check(qv[1] == "Weapon_VSS_VZ" and not has(qv, "Weapon_SCAR_DMR") and not has(qv, "Weapon_SVD_Dragunov"), "an AS Val (bow-like sound) shows only as a VSS, never a loud rifle")
    local hb = W.similar("Weapon_Hunter85_V2", "hunters", { "Weapon_SVD_Dragunov", "Weapon_MosinNagant" })
    check(hb[1] == "Weapon_MosinNagant" and not has(hb, "Weapon_SVD_Dragunov"), "a bolt-action shows a bolt-action")
    local gr = W.similar("Weapon_M1_Garand", "military_group", { "Weapon_AWP", "Weapon_AWM", "Weapon_SVD_Dragunov" })
    check(not has(gr, "Weapon_AWP") and not has(gr, "Weapon_AWM"), "a semi-auto never shows as a bolt-action sniper")
    for _, n in ipairs(W.similar("Weapon_BlackHawk_Crossbow", "hunters", { "Weapon_SCAR_DMR" })) do
        check(W.group(n) == "crossbow", "a crossbow shows only crossbows (" .. n .. ")")
    end
    -- The weapon is picked once and kept through a save.
    local world, d = fresh(41)
    local g = first_group(world)
    local lo = d:loadout_for(g, g.members[1])
    local picked = g.members[1].gear.weapon
    check(lo.Weapons[1] == picked and lo.ordered and lo.Kunto ~= nil, "a member's own weapon goes first, with its condition")
    local w2 = Population.deserialize(Population.serialize(world))
    local g2 = w2.by_gid[g.gid]
    check(g2.members[1].gear and g2.members[1].gear.weapon == picked, "and the NPC keeps it across a restart")
end

section("fights with players go to SCUM's own AI")
do
    local world, d = fresh(51)
    local g = first_group(world)
    local m = g.members[1]
    m.gear = { weapon = "Weapon_Hunter85_V2", scoped = true, condition = 0.8 }
    local sim = os.time()
    local function at(dist)
        Bridge.players = { { X = g.position.X + dist, Y = g.position.Y, Z = 0 } }
        for _ = 1, 3 do sim = sim + 1; Bridge.step(1); d:tick(sim) end
    end
    at(8000)
    check(g.physical and m.runtime_id and Bridge.native[m.runtime_id], "a player within a scoped rifle's reach: SCUM's AI fights")
    local h = m.runtime_id
    Bridge.players = { { X = g.position.X + 60000, Y = g.position.Y, Z = 0 } }
    for _ = 1, 25 do sim = sim + 1; Bridge.step(1); d:tick(sim) end
    check(not m.runtime_id or not Bridge.native[h], "the player gone for a while: the director takes the NPC back")
end

section("a bigger population, lively Z sectors")
do
    local Zones = require("world.zones")
    local world = Population.new_world({ seed = 31, target_npcs = 200 })
    Population.generate(world)
    local z, all = 0, 0
    for _, g in ipairs(world.groups) do
        if not Zones.reserved_by_class[g.class] then
            all = all + 1
            if Zones.sector(g.position):sub(1, 1) == "Z" then z = z + 1 end
        end
    end
    check(Population.alive_npc_count(world) >= 195, string.format("a world of %d NPCs", Population.alive_npc_count(world)))
    check(z / all >= 0.25, string.format("the Z row holds its share of the squads (%d of %d)", z, all))
    local w2 = Population.new_world({ seed = 32, target_npcs = 60 })
    Population.generate(w2)
    local n0 = Population.alive_npc_count(w2)
    w2.pending_growth = 20
    for _ = 1, 10 do Population.grow(w2) end
    check(Population.alive_npc_count(w2) >= n0 + 20 and w2.pending_growth == 0,
          "a raised NPC target grows a saved world")
end

-- -------------------------------------------------------------------------
section("the undead in the abstract")
do
    local world, d = fresh(14)
    -- Ordinary people (ex-soldiers take the same encounters far calmer).
    local g = first_group(world)
    for _, m in ipairs(g.members) do m.archetype = "scavenger" end
    local city = nil
    for _, p in ipairs(POI.points) do
        if p.kind == "CITY" and not p.blocked and not require("world.zones").reserved_for_poi(p) then city = p; break end
    end
    g.act.goal_poi = city
    g.act.state = "SEARCH"
    g.act.until_t = os.time() + 100000
    g.position = U.copy_vec(city.pos)
    local sim = os.time()
    local peak = 0
    -- Encounters are random (about two in 15 minutes of searching): the
    -- squad keeps at it until it has met the dead three times.
    local events = 0
    local start = avg_stress(g)
    for _ = 1, 10800 do
        if events >= 3 then break end
        sim = sim + 1
        g.act.state = "SEARCH"; g.act.until_t = sim + 100
        local before = g.zombie_at
        d:tick(sim)
        if g.zombie_at ~= before then events = events + 1 end
        peak = math.max(peak, avg_stress(g))
    end
    check(events >= 3 and peak > start + 0.1, string.format(
        "a squad searching a city runs into zombies (%d encounters, stress %.2f -> peak %.2f)", events, start, peak))
end

-- -------------------------------------------------------------------------
section("spawning and removing squads from the map")
do
    local Commands = require("sim.commands")
    local Zones = require("world.zones")
    local world, d = fresh(21)
    local dir = os.tmpname()
    os.remove(dir)
    os.execute("mkdir -p " .. dir)
    Commands.configure(dir, "/")
    local land = nil
    for _, p in ipairs(POI.points) do
        if p.kind == "VILLAGE" and not p.blocked and Zones.sector(p.pos) ~= "C0" then land = p.pos; break end
    end
    local c0 = Zones.random_point_in("C0")
    local f = io.open(dir .. "/commands.txt", "w")
    f:write(string.format("c1 spawn police_patrol 3 %d %d\n", math.floor(land.X), math.floor(land.Y)))
    f:write(string.format("c2 spawn police_patrol 3 %d %d\n", math.floor(c0.X), math.floor(c0.Y)))
    f:write(string.format("c3 spawn radiation_group 3 %d %d\n", math.floor(c0.X), math.floor(c0.Y)))
    f:write("c4 spawn no_such_class 3 0 0\n")
    f:close()
    local before = #world.groups
    d:tick(os.time() + 10)
    local res = {}
    for _, r in ipairs(d.command_results or {}) do res[r.id] = r end
    check(res.c1 and res.c1.ok, "a police patrol is spawned where the map was clicked: " .. tostring(res.c1 and res.c1.text))
    local g = nil
    for _, x in ipairs(world.groups) do
        if x.class == "police_patrol" and (not g or x.id > g.id) then g = x end
    end
    check(g.class == "police_patrol" and #g.members == 3 and U.dist2d(g.position, land) < 20000,
          "with the chosen size, at that spot")
    check(res.c2 and not res.c2.ok, "nobody but radiation squads may be put in C0: " .. tostring(res.c2 and res.c2.text))
    check(res.c3 and res.c3.ok, "a radiation squad may")
    check(res.c4 and not res.c4.ok, "an unknown class is refused")
    check(#world.groups == before + 2, "exactly the two allowed squads were added")
    check(io.open(dir .. "/commands.txt", "r") == nil, "the command file was taken")
    -- Remove it again.
    f = io.open(dir .. "/commands.txt", "w")
    f:write("c5 remove " .. g.gid .. "\n")
    f:close()
    d:tick(os.time() + 20)
    res = {}
    for _, r in ipairs(d.command_results or {}) do res[r.id] = r end
    check(res.c5 and res.c5.ok and world.by_gid[g.gid] == nil, "and removed from the map")
    Commands.configure(nil)
    os.execute("rm -rf " .. dir)
end

-- -------------------------------------------------------------------------
section("own squad classes and shared gear")
do
    local Groups = require("npc.groups")
    local Diplomacy = require("npc.diplomacy")
    local Physical = require("sim.physical")
    local notes = Groups.register_custom({
        { avain = "palomiehet", nimi = "Palomiehet", koko = { 2, 4 }, tausta = { "security" },
          kohteet = { CITY = 4, INDUSTRIAL = 3 }, maara = 2, runko = "Guard", vihamieliset = { "bandit_gang" } },
        { avain = "laakarit", nimi = "Lääkärit", tausta = { "civilian", "nobody" }, kohteet = { MEDICAL = 6, MOON = 1 } },
        { avain = "Bad Key" },
        { avain = "police_patrol" },
    })
    local text = table.concat(notes, " / ")
    check(Groups.get("palomiehet") and Groups.get("palomiehet").fi == "Palomiehet", "a new class is registered from ryhmat.lua")
    check(text:find("nobody", 1, true) and text:find("MOON", 1, true), "unknown backgrounds and places are reported, not fatal")
    check(text:find("Bad Key", 1, true) == nil and text:find("#3", 1, true), "a bad key is reported")
    check(not Groups.get("police_patrol").custom, "the mod's own classes cannot be overwritten")
    for _, cls in ipairs(Groups.list) do
        if cls.custom then for _, o in ipairs(cls.hostile_to) do Diplomacy.set_default(cls.key, o, -0.7) end end
    end
    check(Diplomacy.default_standing("palomiehet", "bandit_gang") <= -0.35, "declared enemies start hostile")

    local world, d = fresh(31)
    Population.ensure_custom(world)
    local n = { palomiehet = 0, laakarit = 0 }
    for _, g in ipairs(world.groups) do if n[g.class] then n[g.class] = n[g.class] + 1 end end
    check(n.palomiehet == 2 and n.laakarit == 1, string.format(
        "each own class has its promised squads on the map (%d firefighters, %d doctors)", n.palomiehet, n.laakarit))
    local ff
    for _, g in ipairs(world.groups) do if g.class == "palomiehet" then ff = g end end
    check(Physical.body_family(ff.members[1], ff) == "Guard", "and wears the chosen body")
    local sizes_ok = #ff.members >= 2 and #ff.members <= 4
    check(sizes_ok, "and has the chosen size")

    d.cfg.Loadouts = { KAIKKI = { Clothes = { "Christmas_Pants_02" } },
                       palomiehet = { Clothes = { "Firefighter_Jacket" }, Weapons = { "Weapon_Axe" } } }
    local lo = d:loadout_for(ff)
    check(lo.Clothes[1] == "Christmas_Pants_02" and lo.Clothes[2] == "Firefighter_Jacket"
          and lo.Weapons[1] == "Weapon_Axe", "KAIKKI gear goes to every squad, on top of its own")
    local other = world.groups[1]
    local lo2 = d:loadout_for(other)
    check(lo2 and lo2.Clothes[1] == "Christmas_Pants_02", "including squads with no gear of their own")
    local W = require("npc.weapons")
    d.cfg.Loadouts = {}
    local function has(list, n) for _, x in ipairs(list) do if x == n then return true end end return false end
    local pol = W.for_member("police_patrol", 4, {}, 0.9)
    check(has(pol.Weapons, "Weapon_MP5") and not has(pol.Weapons, "Weapon_AK47"), "police carry SMGs, not AKs")
    check(has(W.for_member("police_patrol", 3, {}, 0.9).Weapons, "Weapon_M1911"), "and pistols")
    local h3, h4 = W.for_member("hunters", 3, {}, 0.9), W.for_member("hunters", 4, {}, 0.9)
    check(has(h3.Weapons, "Weapon_98k_Karabiner") and has(h3.Weapons, "Weapon_Hunter85_V2")
          and has(h4.Weapons, "Compound_Bow") and has(h4.Weapons, "Weapon_BlackHawk_Crossbow")
          and has(h4.Weapons, "Weapon_CarbonHunter") and not has(h4.Weapons, "Weapon_MP5") and h4.TahtainOsuus > 0,
          "hunters carry bolt-action rifles, good bows and crossbows, some scoped")
    local weak = W.for_member("bandit_gang", 1, {}, 0.9)
    check(has(weak.Weapons, "1H_Wooden_club") and not has(weak.Weapons, "Weapon_AK47"), "a weak bandit gets improvised melee")
    check(has(W.for_member("bandit_gang", 5, {}, 0.9).Weapons, "Weapon_AK47"), "a skilled bandit an AK")
    check(has(W.for_member("elite_unit", 1, {}, 0.1).Weapons, "Weapon_SCAR_DMR")
          and has(W.for_member("military_group", 1, {}, 0.1).Weapons, "Weapon_M16A4"),
          "the elite always carry the best, soldiers never below assault rifles")
    check(W.tier("bandit_gang", 3, 0.1) == 2 and W.tier("bandit_gang", 3, 0.9) == 3, "now and then one tier lower")
    check(#W.for_member("palomiehet_x", 2, {}, 0.9).Weapons > 0, "a squad with no theme uses every weapon of its tier")
    do
        local saved = Population.serialize(world)
        local n0 = #saved.groups
        saved.groups[1].class = "poistettu_luokka"
        local w2 = Population.deserialize(saved)
        check(#w2.groups == n0 - 1 and w2.dropped_classes.poistettu_luokka == 1,
              "a saved squad of a removed class is left out when the world loads")
    end
    local all = {}
    for _, t in ipairs(W.TIERS) do for _, n in ipairs(t) do all[#all + 1] = n end end
    local bad = 0
    for _, n in ipairs(all) do
        local l = n:lower()
        if l:find("_gold") or l:find("_engraved") or l:find("_premium") or l:find("_jayw") or l:find("ivory")
            or l:find("rpg") or l:find("at4") or l:find("grenade") or l:find("dannymachete") then bad = bad + 1 end
    end
    check(#all > 100 and bad == 0, string.format("%d weapons in the tiers, no DLC or launchers", #all))
    d.cfg.Loadouts = { police_patrol = { Weapons = {} }, hunters = { Weapons = { "Weapon_98k_Karabiner" }, Lipas = false } }
    check(#d:loadout_for({ class = "police_patrol", members = {} }).Weapons > 0
          and d:loadout_for({ class = "police_patrol", members = {} }).Weapons[1] ~= nil, "an empty list in varusteet.lua keeps the defaults")
    local h2 = d:loadout_for({ class = "hunters", members = {} })
    check(h2.Weapons[1] == "Weapon_98k_Karabiner" and #h2.Weapons == 1 and h2.Lipas == false,
          "an own list replaces the defaults, Lipas = false is kept")
    check(W.magazine_for("Weapon_AKM") == "Magazine_AK47" and W.magazine_for("Weapon_M1887") == nil
          and W.scopes_for("Weapon_Hunter85_V2")[1] == "WeaponScope_HuntingScope",
          "each weapon has its own magazine (none for built-in ones) and scope")
    d.cfg.Loadouts = { KAIKKI = { Asu = 0 }, palomiehet = { Asu = { 2, 5 } } }
    check(d:loadout_for(ff).Asu[2] == 5 and d:loadout_for(other).Asu == 0,
          "an outfit number: the squad's own wins over KAIKKI")
    local notes = Groups.apply_bodies({ KAIKKI = { Runko = "Guard" }, palomiehet = { Runko = "bunker" },
                                        radiation_group = { Runko = "Drifter" } })
    check(Groups.get("pair").body == "Guard" and Physical.body_family(other.members[1], { class = "pair" }) == "Guard",
          "Runko under KAIKKI dresses every squad as that NPC type")
    check(Physical.body_variant({ class = "palomiehet" }, {}) == "AbandonedBunker",
          "a squad's own Runko wins, and a variant body works too")
    check(Physical.body_variant({ class = "radiation_group" }, {}) == "Radiation",
          "the radiation squads keep the hazmat body whatever is set")
    check(#notes >= 3, "each Runko is reported at boot")
    for _, c in ipairs(Groups.list) do c.body, c.variant = nil, nil end
    -- Put things back for any later test in this file.
    for i = #Groups.list, 1, -1 do
        if Groups.list[i].custom then Groups.by_key[Groups.list[i].key] = nil; table.remove(Groups.list, i) end
    end
end

print("")
os.exit(fails == 0 and 0 or 1)
