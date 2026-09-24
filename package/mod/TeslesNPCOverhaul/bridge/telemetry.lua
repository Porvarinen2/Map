-- Writes the live map snapshot.
--
-- The snapshot is deliberately explicit about what is virtual and what is
-- physical, and carries the subsystem health so the browser can show the same
-- honest status the guide asks for: a moving marker is a virtual position, and
-- a green catalog is not proof of a spawn.
local U = require("core.util")
local Log = require("core.log")
local Grid = require("world.navgrid")
local Zones = require("world.zones")
local Traits = require("npc.traits")
local Skills = require("npc.skills")
local Stress = require("npc.stress")
local Trauma = require("npc.trauma")
local Diplomacy = require("npc.diplomacy")
local Activity = require("sim.activity")
local Physical = require("sim.physical")
local Utility = require("npc.utility")
local Archetypes = require("npc.archetypes")
local GroupClasses = require("npc.groups")
local Buildings = require("sim.buildings")
local POI = require("world.pois")

local T = {}

T.out_dir = nil

function T.configure(dir) T.out_dir = dir end

local function write_file(name, text)
    if not T.out_dir then return false end
    local f = io.open(U.join(T.out_dir, name), "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function round(v, d)
    d = d or 0
    local m = 10 ^ d
    return math.floor((tonumber(v) or 0) * m + 0.5) / m
end

local function npc_row(m, group)
    local top_traits = {}
    for _, key in ipairs(Traits.keys) do
        top_traits[#top_traits + 1] = { k = key, v = Trauma.trait(m, key) }
    end
    table.sort(top_traits, function(a, b) return a.v > b.v end)
    local dominant = {}
    for i = 1, math.min(5, #top_traits) do
        local t = Traits.index[top_traits[i].k]
        dominant[#dominant + 1] = { name = t and t.fi or top_traits[i].k,
                                    value = round(top_traits[i].v, 2) }
    end

    -- Trait and skill names are sent once per snapshot in traitDefs/skillDefs;
    -- each NPC carries only the values, in the same order. With a hundred NPCs
    -- that is the difference between a 480 KB and a 190 KB poll.
    local skills = {}
    for i, s in ipairs(Skills.list) do
        skills[i] = round(m.skills[s.key] or 0, 2)
    end

    local traits = {}
    for i, t in ipairs(Traits.list) do
        traits[i] = round(Trauma.trait(m, t.key), 2)
    end

    local stress_key, stress_fi = Stress.state_of(m.stress)
    local arch = Archetypes.get(m.archetype)
    return {
        npcId = m.npcId,
        name = m.name,
        archetype = m.archetype,
        archetype_fi = arch and arch.fi or m.archetype,
        level = m.level,
        level_name = Skills.level_name[m.level] or "",
        alive = m.alive,
        leader = m.is_leader or false,
        health = round(m.health or 0, 0),
        stress = round(m.stress or 0, 2),
        stress_state = stress_key,
        stress_fi = stress_fi,
        morale = round(m.morale or 0, 2),
        action = m.action or "IDLE",
        action_fi = Utility.fi[m.action or ""] or "",
        physical = m.materialized == true,
        traumas = Trauma.summary(m),
        dominant = dominant,
        traits = traits,
        skills = skills,
        xp = m.xp,
        memories = (function()
            local out = {}
            local mem = m.memories or {}
            for i = math.max(1, #mem - 5), #mem do
                if mem[i] then
                    out[#out + 1] = { kind = mem[i].kind, detail = mem[i].detail,
                                      t = mem[i].t }
                end
            end
            return out
        end)(),
    }
end

local function group_row(group, world)
    local act = group.act or {}
    local mv = group.mv or {}
    local alive, physical = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then alive = alive + 1 end
        if m.materialized then physical = physical + 1 end
    end

    local route = nil
    if mv.route and mv.route.points then
        route = {}
        local pts = mv.route.points
        -- Send the remaining route only; the browser draws it as the plan.
        for i = math.max(1, (mv.index or 1) - 1), #pts do
            route[#route + 1] = { round(pts[i].X, 0), round(pts[i].Y, 0) }
        end
    end

    local cls = GroupClasses.get(group.class)
    local members = {}
    for _, m in ipairs(group.members) do
        members[#members + 1] = npc_row(m, group)
    end

    local rel = {}
    if world then
        for _, other in ipairs(world.groups) do
            if other ~= group then
                local v = Diplomacy.standing(world.diplomacy, group, other)
                local tier = Diplomacy.tier(v)
                if tier ~= "NEUTRAL" then
                    rel[#rel + 1] = { gid = other.gid, value = round(v, 2), tier = tier }
                end
            end
        end
    end

    local history = {}
    for _, h in ipairs(act.history or {}) do history[#history + 1] = h.text end

    -- The places planned after the current goal, in order.
    local queue = {}
    for _, id in ipairs(act.queue or {}) do
        local p = POI.by_id[id]
        if p then
            queue[#queue + 1] = { id = p.id, label = p.label, kind = p.kind,
                                  x = round(p.pos.X, 0), y = round(p.pos.Y, 0) }
        end
    end
    local goal_pos = act.goal_poi and act.goal_poi.pos

    return {
        gid = group.gid,
        name = group.name,
        class = group.class,
        class_fi = cls and cls.fi or group.class,
        tactics = group.tactics,
        x = round(group.position and group.position.X or 0, 0),
        y = round(group.position and group.position.Y or 0, 0),
        z = round(group.position and group.position.Z or 0, 0),
        sector = group.position and Zones.sector(group.position) or "OUT",
        members_total = #group.members,
        members_alive = alive,
        physical_members = physical,
        virtualized = not group.physical,
        lod = group.lod or "VIRTUAL",
        player_distance_m = (group.player_distance and group.player_distance < 1e8)
            and round(group.player_distance / 100, 0) or -1,
        level = group.level,
        morale = round(group.morale or 0, 2),
        cohesion = round(group.cohesion or 0, 2),
        leader = group.leader_id,
        leaderless = group.leaderless or false,
        state = act.state or "IDLE",
        state_fi = Activity.fi[act.state or ""] or act.state or "",
        goal = act.goal_poi and act.goal_poi.label or nil,
        goal_id = act.goal_poi and act.goal_poi.id or nil,
        goal_kind = act.goal_poi and act.goal_poi.kind or nil,
        goal_x = goal_pos and round(goal_pos.X, 0) or nil,
        goal_y = goal_pos and round(goal_pos.Y, 0) or nil,
        queue = queue,
        recent = #(act.recent or {}),
        intent = Activity.describe(group, act),
        route = route,
        route_kind = mv.route and mv.route.kind or nil,
        route_km = mv.route and round(mv.route.length / 100000, 2) or 0,
        route_index = mv.index or 1,
        fatigue = round(act.fatigue or 0, 0),
        supply = round(act.supply or 0, 0),
        distance_km = round((act.distance or 0) / 100000, 1),
        journeys = act.journeys or 0,
        stress = round(Stress.group_stress(group), 2),
        power = round(Utility.group_power(group), 2),
        commands = mv.commands or 0,
        stalls = mv.stalls or 0,
        search_note = group.search_note,
        search_proof = group.search and Buildings.proof(group.search) or nil,
        spawn_note = group.spawn_note,
        relations = rel,
        history = history,
        members = members,
    }
end

-- Builds the whole snapshot table.
function T.snapshot(world, bridge, director, extra)
    local groups = {}
    local npcs, alive, physical, zombie_seen = 0, 0, 0, 0
    for _, g in ipairs(world.groups) do
        groups[#groups + 1] = group_row(g, world)
        for _, m in ipairs(g.members) do
            npcs = npcs + 1
            if m.alive then alive = alive + 1 end
            if m.materialized then physical = physical + 1 end
        end
    end

    local health = {}
    for key, h in pairs((bridge and bridge.health) or {}) do
        health[#health + 1] = { key = key, status = h.status, detail = h.detail }
    end
    table.sort(health, function(a, b) return a.key < b.key end)

    local events = {}
    for _, e in ipairs(Log.recent_events(60)) do
        events[#events + 1] = { t = e.t, kind = e.kind, subject = e.subject,
                                detail = e.detail }
    end

    local traitDefs = {}
    for i, t in ipairs(Traits.list) do
        traitDefs[i] = { name = t.fi, key = t.key, effect = t.effect }
    end
    local skillDefs = {}
    for i, s in ipairs(Skills.list) do
        skillDefs[i] = { name = s.fi, key = s.key, group = s.group }
    end

    -- Players as the director sees them (after the join grace), and the
    -- distance to the nearest group, so the map can answer "where are the
    -- NPCs relative to me".
    local players = {}
    local plist = (bridge and bridge.player_positions and bridge.player_positions()) or {}
    for _, p in ipairs(plist) do
        local best = nil
        for _, g in ipairs(world.groups) do
            if g.position then
                local dx, dy = g.position.X - p.X, g.position.Y - p.Y
                local d = math.sqrt(dx * dx + dy * dy)
                if not best or d < best.d then best = { d = d, gid = g.gid } end
            end
        end
        players[#players + 1] = { x = p.X, y = p.Y,
            nearest_gid = best and best.gid or nil,
            nearest_m = best and math.floor(best.d / 100) or nil }
    end

    return {
        players = players,
        version = extra and extra.version or "1.0.0",
        traitDefs = traitDefs,
        skillDefs = skillDefs,
        t = os.time(),
        uptime = extra and extra.uptime or 0,
        tick = director and director.ticks or 0,
        calibration = {
            xWest = Grid.xWest, xEast = Grid.xEast,
            yNorth = Grid.yNorth, ySouth = Grid.ySouth,
        },
        stats = {
            npcs = npcs, alive = alive, physical = physical,
            groups = #world.groups, zombies = zombie_seen,
            routes = director and director.counters.routes or 0,
            route_fail = director and director.counters.route_fail or 0,
            commands = director and director.counters.commands or 0,
            arrivals = director and director.counters.arrivals or 0,
            spawns = director and director.counters.spawns or 0,
            spawn_fail = director and director.counters.spawn_fail or 0,
            deaths = director and director.counters.deaths or 0,
            contacts = director and director.counters.contacts or 0,
            replans = director and director.counters.replans or 0,
        },
        lod = {
            full_m = Physical.tuning.full_uu / 100,
            light_m = Physical.tuning.light_uu / 100,
            materialize_m = Physical.tuning.materialize_uu / 100,
            virtualize_m = Physical.tuning.virtualize_uu / 100,
        },
        health = health,
        groups = groups,
        events = events,
    }
end

-- Writes the snapshot atomically enough for a polling reader: a temp file is
-- written first, then renamed, so the browser never reads a half file.
function T.write(world, bridge, director, extra)
    local snap = T.snapshot(world, bridge, director, extra)
    local json = U.json(snap)
    local ok = write_file("live_state.json.tmp", json)
    if not ok then return false end
    local a = U.join(T.out_dir, "live_state.json.tmp")
    local b = U.join(T.out_dir, "live_state.json")
    if os.rename(a, b) then return true end
    -- Windows refuses a rename onto an existing file.
    os.remove(b)
    if os.rename(a, b) then return true end
    return write_file("live_state.json", json)
end

return T
