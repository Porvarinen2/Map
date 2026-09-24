-- The persistent world population.
--
-- Groups exist whether or not a player is nearby. They are created once at
-- world birth, saved to disk, and restored on restart with their identities,
-- personalities, positions and goals intact. Nothing here spawns anything in
-- the engine: that is the physical layer's job.
local U = require("core.util")
local RNG = require("core.rng")
local Factory = require("npc.factory")
local GroupClasses = require("npc.groups")
local Leadership = require("npc.leadership")
local Diplomacy = require("npc.diplomacy")
local Skills = require("npc.skills")
local Grid = require("world.navgrid")
local Zones = require("world.zones")
local POI = require("world.pois")
local Activity = require("sim.activity")
local Movement = require("sim.movement")

local P = {}

P.HARD_CAP = 250

function P.new_world(opts)
    opts = opts or {}
    return {
        seed = opts.seed or os.time(),
        groups = {},
        by_gid = {},
        next_group_id = 1,
        diplomacy = Diplomacy.new_registry(),
        created_at = os.time(),
        target_npcs = math.min(P.HARD_CAP, opts.target_npcs or 100),
        stats = {},
    }
end

-- Spawn anchor: a passable point, preferring somewhere near a POI so groups
-- start their life somewhere plausible rather than in empty forest.
local function anchor_point(rng, allow_sector)
    for _ = 1, 80 do
        local poi = POI.points[rng:int(1, POI.count)]
        if poi and not poi.blocked and (not allow_sector or allow_sector(poi)) then
            local ang = rng:float() * math.pi * 2
            local d = rng:range(0, poi.radius or 9000)
            local p = {
                X = poi.pos.X + math.cos(ang) * d,
                Y = poi.pos.Y + math.sin(ang) * d,
                Z = poi.pos.Z,
            }
            if Grid.is_passable(p) then return p, poi end
        end
    end
    return nil
end

function P.attach_runtime(world, group)
    group.act = group.act or Activity.new_state(group.seed)
    group.mv = group.mv or Movement.new_state()
    group.level = Skills.group_level(group.members)
    if not Leadership.leader(group) then
        Leadership.assign(group, (Leadership.select(group)))
    end
    return group
end

function P.add_group(world, group)
    group.id = group.id or world.next_group_id
    if group.id >= world.next_group_id then world.next_group_id = group.id + 1 end
    group.gid = group.gid or string.format("SQD_%04d", group.id)
    world.groups[#world.groups + 1] = group
    world.by_gid[group.gid] = group
    P.attach_runtime(world, group)
    return group
end

function P.alive_npc_count(world)
    local n = 0
    for _, g in ipairs(world.groups) do
        for _, m in ipairs(g.members) do
            if m.alive then n = n + 1 end
        end
    end
    return n
end

function P.group_alive(group)
    for _, m in ipairs(group.members) do
        if m.alive then return true end
    end
    return false
end

-- Builds the world population from scratch: reserved zones first, then
-- general groups until the NPC target is met.
function P.generate(world, log)
    local rng = RNG.new(world.seed)
    local created = 0

    -- Reserved sectors get their guaranteed groups.
    for _, res in ipairs(Zones.RESERVED) do
        local mass = Zones.dominant_landmass(res.sector)
        for _ = 1, res.groups do
            local pos = nil
            for _ = 1, 60 do
                local p = Zones.random_point_in(res.sector, rng)
                if p and (not mass or Grid.landmass_at(p) == mass) then pos = p; break end
            end
            pos = pos or Zones.random_point_in(res.sector, rng)
            if pos then
                local g = Factory.new_group({
                    id = world.next_group_id,
                    class = res.class,
                    seed = rng:next(),
                    position = pos,
                    home = pos,
                    zone = res.key,
                })
                P.add_group(world, g)
                created = created + #g.members
            end
        end
    end

    -- General population. Reserved sectors are off limits.
    local general = GroupClasses.general()
    local pool = {}
    for _, g in ipairs(general) do pool[#pool + 1] = { key = g.key, weight = g.weight } end

    local guard = 0
    while P.alive_npc_count(world) < world.target_npcs and guard < 500 do
        guard = guard + 1
        local pick = U.weighted_pick(pool, rng)
        if not pick then break end
        local pos = anchor_point(rng, function(poi)
            return not Zones.reserved_by_sector[poi.sector]
        end)
        if pos then
            local remaining = world.target_npcs - P.alive_npc_count(world)
            local cls = GroupClasses.get(pick.key)
            local size = rng:int(cls.size[1], cls.size[2])
            if size > remaining then size = math.max(cls.size[1], remaining) end
            local g = Factory.new_group({
                id = world.next_group_id,
                class = pick.key,
                seed = rng:next(),
                position = pos,
                home = pos,
                size = size,
            })
            P.add_group(world, g)
            created = created + #g.members
        end
    end

    if log then
        log(string.format("world population: %d NPCs in %d groups (target %d)",
            P.alive_npc_count(world), #world.groups, world.target_npcs))
    end
    return world
end

-- Keeps the exclusive zones exactly as the design says, for a new world and
-- for a saved one from an older version: the zone's class has its fixed
-- number of squads, all of them inside, and no other squad stands in it.
-- Only virtual groups are moved; a group with bodies in the world is left
-- to walk out on its own (its routes are fenced).
function P.ensure_reserved(world, log)
    local changed = 0
    local rng = RNG.new((world.seed or 1) + (world.next_group_id or 0) * 7919)
    for _, res in ipairs(Zones.RESERVED) do
        if res.exclusive then
            local mass = Zones.dominant_landmass(res.sector)
            local function inside_point()
                for _ = 1, 80 do
                    local p = Zones.random_point_in(res.sector, rng)
                    if p and (not mass or Grid.landmass_at(p) == mass) then return p end
                end
                return Zones.random_point_in(res.sector, rng)
            end
            local own = 0
            for _, g in ipairs(world.groups) do
                if P.group_alive(g) and g.position and not g.physical then
                    local here = Zones.sector(g.position) == res.sector
                    if g.class == res.class and not here then
                        local p = inside_point()
                        if p then
                            g.position, g.home = p, U.copy_vec(p)
                            for _, m in ipairs(g.members) do m.position = U.copy_vec(p) end
                            if g.act then g.act.goal_poi, g.act.queue, g.act.state = nil, {}, "IDLE" end
                            if g.mv then g.mv.route = nil end
                            changed = changed + 1
                        end
                    elseif g.class ~= res.class and here then
                        local p = anchor_point(rng, function(poi)
                            return not Zones.reserved_by_sector[poi.sector] and not poi.blocked
                        end)
                        if p then
                            g.position = p
                            if Zones.sector(g.home or p) == res.sector then g.home = U.copy_vec(p) end
                            for _, m in ipairs(g.members) do m.position = U.copy_vec(p) end
                            if g.act then g.act.goal_poi, g.act.queue, g.act.state = nil, {}, "IDLE" end
                            if g.mv then g.mv.route = nil end
                            changed = changed + 1
                        end
                    end
                end
                if g.class == res.class and P.group_alive(g) then own = own + 1 end
            end
            while own < res.groups do
                local pos = inside_point()
                if not pos then break end
                local g = Factory.new_group({
                    id = world.next_group_id, class = res.class, seed = rng:next(),
                    position = pos, home = pos, zone = res.key,
                })
                P.add_group(world, g)
                own = own + 1
                changed = changed + 1
                if log then log("reserved zone " .. res.sector .. ": added " .. g.gid) end
            end
        end
    end
    return changed
end

-- Auto-grouping from the guide: a lone survivor near a compatible group joins
-- it, within a 20 m radius and a five-member ceiling. Bandits never mix with
-- other backgrounds. This is how a wiped-out squad's last member stops being a
-- permanent solo wanderer.
P.JOIN_RADIUS_UU = 2000
P.MAX_GROUP_SIZE = 5

function P.merge_stragglers(world, log)
    local merged = 0
    for _, solo in ipairs(world.groups) do
        local alive = {}
        for _, m in ipairs(solo.members) do
            if m.alive then alive[#alive + 1] = m end
        end
        if #alive == 1 and solo.position and not solo.home_bound then
            for _, host in ipairs(world.groups) do
                if host ~= solo and host.position then
                    local host_alive = 0
                    for _, m in ipairs(host.members) do
                        if m.alive then host_alive = host_alive + 1 end
                    end
                    if host_alive >= 1 and host_alive < P.MAX_GROUP_SIZE
                        and U.dist2d(solo.position, host.position) <= P.JOIN_RADIUS_UU
                        and Diplomacy.compatible(alive[1], host.members[1]) then
                        local joiner = alive[1]
                        joiner.group_id = host.gid
                        joiner.is_leader = false
                        host.members[#host.members + 1] = joiner
                        for i, m in ipairs(solo.members) do
                            if m == joiner then table.remove(solo.members, i); break end
                        end
                        host.level = Skills.group_level(host.members)
                        host.cohesion = U.clamp((host.cohesion or 0.7) - 0.08, 0, 1)
                        merged = merged + 1
                        if log then
                            log(joiner.name .. " liittyi ryhmaan " .. host.gid)
                        end
                        break
                    end
                end
            end
        end
    end
    return merged
end

-- Removes groups whose members are all dead. Dead NPCs are not automatically
-- replaced; that is a deliberate default from the guide.
function P.prune(world, log)
    local kept = {}
    local removed = 0
    for _, g in ipairs(world.groups) do
        if P.group_alive(g) then
            kept[#kept + 1] = g
        else
            world.by_gid[g.gid] = nil
            removed = removed + 1
            if log then log("group wiped out: " .. g.gid .. " (" .. g.class .. ")") end
        end
    end
    world.groups = kept
    return removed
end

-- Optional respawn to keep the world from emptying out over weeks.
function P.replenish(world, log)
    if P.alive_npc_count(world) >= world.target_npcs then return 0 end
    local rng = RNG.new(world.seed + os.time())
    local pool = {}
    for _, g in ipairs(GroupClasses.general()) do
        pool[#pool + 1] = { key = g.key, weight = g.weight }
    end
    local pick = U.weighted_pick(pool, rng)
    if not pick then return 0 end
    local pos = anchor_point(rng, function(poi)
        return not Zones.reserved_by_sector[poi.sector]
    end)
    if not pos then return 0 end
    local g = Factory.new_group({
        id = world.next_group_id, class = pick.key, seed = rng:next(),
        position = pos, home = pos,
    })
    P.add_group(world, g)
    if log then log("replenished group " .. g.gid .. " (" .. g.class .. ")") end
    return #g.members
end

function P.stats(world)
    local s = {
        groups = #world.groups, npcs = 0, alive = 0, physical = 0,
        by_class = {}, by_state = {}, by_archetype = {}, leaders = 0,
    }
    for _, g in ipairs(world.groups) do
        s.by_class[g.class] = (s.by_class[g.class] or 0) + 1
        local st = g.act and g.act.state or "IDLE"
        s.by_state[st] = (s.by_state[st] or 0) + 1
        if g.leader_id then s.leaders = s.leaders + 1 end
        for _, m in ipairs(g.members) do
            s.npcs = s.npcs + 1
            if m.alive then s.alive = s.alive + 1 end
            if m.materialized then s.physical = s.physical + 1 end
            s.by_archetype[m.archetype] = (s.by_archetype[m.archetype] or 0) + 1
        end
    end
    return s
end

-- --------------------------------------------------------- serialisation ---

-- Only durable facts are saved. Routes, engine handles and derived values are
-- rebuilt on load, so a saved world never carries a stale actor reference.
function P.serialize(world)
    local out = {
        version = 1,
        seed = world.seed,
        created_at = world.created_at,
        next_group_id = world.next_group_id,
        target_npcs = world.target_npcs,
        saved_at = os.time(),
        diplomacy = world.diplomacy.pairs,
        groups = {},
    }
    for _, g in ipairs(world.groups) do
        local sg = {
            id = g.id, gid = g.gid, class = g.class, seed = g.seed,
            name = g.name, position = U.copy_vec(g.position),
            home = U.copy_vec(g.home), zone = g.zone,
            morale = g.morale, cohesion = g.cohesion,
            leader_id = g.leader_id, leaderless = g.leaderless,
            home_bound = g.home_bound,
            members = {},
        }
        if g.act then
            sg.act = {
                state = g.act.state,
                goal_id = g.act.goal_poi and g.act.goal_poi.id or nil,
                until_t = g.act.until_t,
                fatigue = g.act.fatigue,
                supply = g.act.supply,
                visited = g.act.visited,
                queue = g.act.queue,
                recent = g.act.recent,
                journeys = g.act.journeys,
                distance = g.act.distance,
                searched = g.act.searched,
                sweep_dir = g.act.sweep_dir,
                tour_index = g.act.sweep_dir and g.act.tour_index or nil,
            }
        end
        for _, m in ipairs(g.members) do
            sg.members[#sg.members + 1] = {
                id = m.id, npcId = m.npcId, name = m.name, seed = m.seed,
                archetype = m.archetype, level = m.level, alive = m.alive,
                health = m.health, stress = m.stress, morale = m.morale,
                action = m.action, injuries = m.injuries,
                is_leader = m.is_leader,
                traumas = m.traumas, relations = m.relations,
                memories = m.memories, xp = m.xp,
            }
        end
        out.groups[#out.groups + 1] = sg
    end
    return out
end

function P.deserialize(saved)
    local world = P.new_world({ seed = saved.seed, target_npcs = saved.target_npcs })
    world.created_at = saved.created_at or os.time()
    world.next_group_id = saved.next_group_id or 1
    world.diplomacy.pairs = saved.diplomacy or {}

    for _, sg in ipairs(saved.groups or {}) do
        local cls = GroupClasses.get(sg.class) or GroupClasses.get("survivor_group")
        local g = {
            id = sg.id, gid = sg.gid, class = sg.class, seed = sg.seed,
            name = sg.name or cls.fi, tactics = cls.tactics,
            position = U.copy_vec(sg.position), home = U.copy_vec(sg.home),
            zone = sg.zone, morale = sg.morale or 0.66,
            cohesion = sg.cohesion or 0.7, leader_id = sg.leader_id,
            leaderless = sg.leaderless, home_bound = sg.home_bound or cls.home_bound,
            members = {}, relations = {}, visited = {},
            state = "IDLE", virtualized = true, physical_count = 0,
        }
        for _, sm in ipairs(sg.members or {}) do
            -- Personality is regenerated from the seed, never from the save:
            -- one source of truth, and a much smaller save file.
            local npc = Factory.new_npc({
                id = sm.id, seed = sm.seed, archetype = sm.archetype,
                level = sm.level, name = sm.name, group_id = sg.gid,
            })
            npc.npcId = sm.npcId or npc.npcId
            npc.alive = sm.alive ~= false
            npc.health = sm.health or 100
            npc.stress = sm.stress or 0
            npc.morale = sm.morale or 0.6
            npc.action = sm.action
            npc.injuries = sm.injuries or 0
            npc.is_leader = sm.is_leader or false
            npc.traumas = sm.traumas or {}
            npc.relations = sm.relations or {}
            npc.memories = sm.memories or {}
            npc.xp = sm.xp or npc.xp
            Factory.reserve_npc_id(npc.id)
            g.members[#g.members + 1] = npc
        end
        if #g.members > 0 then
            P.add_group(world, g)
            if sg.act then
                g.act.state = sg.act.state or "IDLE"
                g.act.until_t = sg.act.until_t or 0
                g.act.fatigue = sg.act.fatigue or 0
                g.act.supply = sg.act.supply or 100
                g.act.visited = sg.act.visited or {}
                g.act.queue = sg.act.queue or {}
                g.act.recent = sg.act.recent or {}
                g.act.journeys = sg.act.journeys or 0
                g.act.distance = sg.act.distance or 0
                g.act.searched = sg.act.searched or 0
                if sg.act.goal_id then g.act.goal_poi = POI.by_id[sg.act.goal_id] end
                -- A sweep resumes at the stop it had reached.
                if sg.act.sweep_dir and g.act.goal_poi then
                    g.act.sweep_dir = sg.act.sweep_dir
                    g.act.tour_index = sg.act.tour_index or 0
                end
                -- A restored group re-solves its route on the next tick.
                if g.act.state == "TRAVEL" then g.act.state = "IDLE" end
            end
        end
    end
    return world
end

return P
