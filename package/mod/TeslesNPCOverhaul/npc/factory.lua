-- Creates individuals and groups. Everything is derived from a seed, so the
-- same npcId always rebuilds the same base personality after a server restart.
local U = require("core.util")
local RNG = require("core.rng")
local Traits = require("npc.traits")
local Skills = require("npc.skills")
local Archetypes = require("npc.archetypes")
local GroupClasses = require("npc.groups")

local F = {}

local FIRST = {
    "Marko", "Ivan", "Damir", "Luka", "Stipe", "Nikola", "Josip", "Ante",
    "Petar", "Goran", "Tomislav", "Zoran", "Vlado", "Mate", "Dario", "Bruno",
    "Ana", "Ivana", "Marija", "Petra", "Lucija", "Nina", "Maja", "Sara",
    "Karlo", "Filip", "Emil", "Roko", "Vid", "Jure", "Silvia", "Tea",
}
local LAST = {
    "Horvat", "Kovac", "Babic", "Maric", "Juric", "Novak", "Kovacevic",
    "Vukovic", "Knezevic", "Matic", "Pavlovic", "Tomic", "Petrovic", "Grgic",
    "Blazevic", "Radic", "Bozic", "Peric", "Lovric", "Sarić",
}

function F.name_for(seed)
    local r = RNG.new(seed * 31 + 7)
    return FIRST[r:int(1, #FIRST)] .. " " .. LAST[r:int(1, #LAST)]
end

-- Rolls the 38 traits: neutral baseline, archetype offset, individual spread.
function F.roll_traits(rng, archetype_key)
    local arch = Archetypes.get(archetype_key)
    local out = {}
    for _, key in ipairs(Traits.keys) do
        local mean = 0.5 + ((arch and arch.traits[key]) or 0)
        out[key] = U.clamp(rng:gauss(mean, 0.13, 0.01, 0.99), 0, 1)
    end
    -- Fear and courage are two sides of the same person: keep them coherent
    -- without making them a rigid mirror.
    out.fearfulness = U.clamp(out.fearfulness * 0.72 + (1 - out.courage) * 0.28, 0, 1)
    return out
end

-- Rolls the 12 skills from the level base plus archetype weighting.
function F.roll_skills(rng, archetype_key, level)
    local arch = Archetypes.get(archetype_key)
    local base = Skills.base_for(level)
    local out = {}
    for _, key in ipairs(Skills.keys) do
        local mean = base + ((arch and arch.skills[key]) or 0)
        out[key] = U.clamp(rng:gauss(mean, 0.09, 0, 1), 0, 1)
    end
    return out
end

local next_npc_id = 1

function F.reserve_npc_id(id)
    if id and id >= next_npc_id then next_npc_id = id + 1 end
end

function F.new_npc(opts)
    opts = opts or {}
    local id = opts.id or next_npc_id
    if id >= next_npc_id then next_npc_id = id + 1 end
    local seed = opts.seed or (id * 2654435761 + 12345)
    local rng = RNG.new(seed)

    local archetype = opts.archetype or "survivor"
    local lo, hi = Archetypes.level_range(archetype)
    -- The level roll is always consumed, even when a stored level overrides
    -- it, so that restoring an NPC from its seed reproduces the exact same
    -- trait and skill draw as the original roll.
    local rolled = rng:int(lo, hi)
    local level = math.max(lo, math.min(hi, opts.level or rolled))
    -- A class that sets the level wins over the archetype's range.
    if opts.class_level then level = opts.class_level end

    local npc = {
        id = id,
        npcId = string.format("NPC_%05d", id),
        name = opts.name or F.name_for(seed),
        seed = seed,
        archetype = archetype,
        level = level,
        traits = F.roll_traits(rng, archetype),
        skills = F.roll_skills(rng, archetype, level),

        -- situation
        alive = true,
        health = 100.0,
        stress = U.clamp(rng:range(0.02, 0.14), 0, 1),
        morale = U.clamp(0.62 + rng:range(-0.08, 0.14), 0, 1),
        action = "IDLE",
        action_score = 0,
        injuries = 0,

        -- social
        group_id = opts.group_id,
        is_leader = false,
        relations = {},
        memories = {},
        traumas = {},

        -- engine link
        runtime_id = nil,
        materialized = false,
        lod = "VIRTUAL",
        body_class = nil,

        -- experience counters
        xp = { fights = 0, kills = 0, zombies = 0, ambushes_survived = 0,
               distance = 0, buildings = 0 },
        created_at = os.time(),
    }
    return npc
end

-- Builds a whole group: class, size, member archetypes, home anchor.
function F.new_group(opts)
    opts = opts or {}
    local class_key = opts.class or "survivor_group"
    local cls = GroupClasses.get(class_key) or GroupClasses.get("survivor_group")
    local seed = opts.seed or os.time()
    local rng = RNG.new(seed)

    local size = opts.size or rng:int(cls.size[1], cls.size[2])
    size = math.max(cls.size[1], math.min(cls.size[2], size))

    local group = {
        id = opts.id,
        gid = opts.gid or string.format("SQD_%04d", opts.id or 0),
        class = class_key,
        name = opts.name or cls.fi,
        tactics = cls.tactics,
        seed = seed,
        members = {},
        leader_id = nil,
        leader_lost_at = nil,
        level = 1,
        morale = 0.66,
        cohesion = 0.70,
        position = opts.position and U.copy_vec(opts.position) or nil,
        home = opts.home and U.copy_vec(opts.home) or
               (opts.position and U.copy_vec(opts.position) or nil),
        home_bound = cls.home_bound or false,
        zone = opts.zone,
        activity = nil,
        destination = nil,
        state = "IDLE",
        virtualized = true,
        physical_count = 0,
        visited = {},
        relations = {},
        created_at = os.time(),
    }

    for i = 1, size do
        local arch = cls.archetypes[rng:int(1, #cls.archetypes)]
        local mseed = seed * 131 + i * 7919
        local npc = F.new_npc({
            archetype = arch,
            seed = mseed,
            group_id = group.gid,
            class_level = GroupClasses.member_level(cls, mseed),
        })
        group.members[i] = npc
    end
    group.level = Skills.group_level(group.members)
    return group
end

return F
