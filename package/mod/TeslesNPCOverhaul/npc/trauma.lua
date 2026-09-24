-- Memories and traumas.
--
-- Memory storage favours important and recent events, as the guide states.
-- Only the trauma kinds with a listed modifier change behaviour; the rest are
-- recorded so the live map can show what an NPC has been through.
local U = require("core.util")

local Tr = {}

Tr.MAX_MEMORIES = 14

Tr.KINDS = {
    OVERCAUTION    = { fi = "Ylivarovaisuus",
                       mods = { cautiousness = 0.18, aggression = -0.10 } },
    FEAR_OF_LOSS   = { fi = "Menettämisen pelko",
                       mods = { fearfulness = 0.14, protectiveness = 0.12 } },
    PARANOIA       = { fi = "Vainoharhaisuus",
                       mods = { paranoia = 0.22, sociability = -0.10 } },
    ZOMBIE_TRAUMA  = { fi = "Zombitrauma",
                       mods = { fearfulness = 0.16, stressResistance = -0.10 } },
    COMBAT_AVERSE  = { fi = "Taistelun välttely",
                       mods = { aggression = -0.20, courage = -0.14 } },
    VENGEFUL       = { fi = "Kostoreaktio",
                       mods = { aggression = 0.18, vindictiveness = 0.20,
                                mercy = -0.12 } },
    TRUST_DAMAGE   = { fi = "Luottamusvaurio",
                       mods = { loyalty = -0.16, teamwork = -0.12 } },
}

-- Which events can produce which trauma, and how likely before resistance.
local TRIGGERS = {
    LEADER_DOWN    = { { "FEAR_OF_LOSS", 0.35 }, { "VENGEFUL", 0.25 }, { "TRUST_DAMAGE", 0.12 } },
    ALLY_DOWN      = { { "FEAR_OF_LOSS", 0.22 }, { "VENGEFUL", 0.18 } },
    SEVERE_INJURY  = { { "OVERCAUTION", 0.34 }, { "COMBAT_AVERSE", 0.20 } },
    NEAR_MISS      = { { "OVERCAUTION", 0.16 }, { "PARANOIA", 0.10 } },
    ZOMBIE_HORDE   = { { "ZOMBIE_TRAUMA", 0.34 } },
    ZOMBIE_CONTACT = { { "ZOMBIE_TRAUMA", 0.10 } },
    AMBUSHED       = { { "PARANOIA", 0.30 }, { "OVERCAUTION", 0.22 } },
}

-- Records a memory. Importance 0..1; low-value memories are dropped first.
function Tr.remember(npc, kind, detail, importance)
    npc.memories = npc.memories or {}
    local m = {
        kind = kind, detail = detail,
        importance = U.clamp(importance or 0.5, 0, 1),
        t = os.time(),
    }
    npc.memories[#npc.memories + 1] = m
    if #npc.memories > Tr.MAX_MEMORIES then
        -- Drop the weakest memory, weighing importance against age.
        local worst, wi = math.huge, 1
        local now = os.time()
        for i, mem in ipairs(npc.memories) do
            local age = math.max(1, now - mem.t)
            local score = mem.importance * 1000 / age
            if score < worst then worst, wi = score, i end
        end
        table.remove(npc.memories, wi)
    end
    return m
end

-- Rolls for a trauma from a stress event. Stress resistance protects.
function Tr.maybe_trauma(npc, event, rng)
    local triggers = TRIGGERS[event]
    if not triggers then return nil end
    local resist = npc.traits and npc.traits.stressResistance or 0.5
    local pressure = 0.55 + (npc.stress or 0) * 0.75
    local got = nil
    for _, t in ipairs(triggers) do
        local chance = t[2] * pressure * (1.3 - resist * 0.8)
        local roll = rng and rng:float() or math.random()
        if roll < chance then
            got = Tr.add(npc, t[1]) or got
        end
    end
    return got
end

function Tr.add(npc, kind)
    local def = Tr.KINDS[kind]
    if not def then return nil end
    npc.traumas = npc.traumas or {}
    if npc.traumas[kind] then
        npc.traumas[kind].count = npc.traumas[kind].count + 1
        return npc.traumas[kind]
    end
    npc.traumas[kind] = { kind = kind, count = 1, t = os.time() }
    return npc.traumas[kind]
end

-- Trait value with trauma modifiers folded in. All decision code reads traits
-- through this so a traumatised NPC genuinely behaves differently.
function Tr.trait(npc, key)
    local base = (npc.traits and npc.traits[key]) or 0.5
    if not npc.traumas or next(npc.traumas) == nil then return base end
    local delta = 0
    for kind, rec in pairs(npc.traumas) do
        local def = Tr.KINDS[kind]
        if def and def.mods[key] then
            -- Repeat traumas deepen, with diminishing returns.
            delta = delta + def.mods[key] * (1 + math.min(2, rec.count - 1) * 0.4)
        end
    end
    return U.clamp(base + delta, 0, 1)
end

function Tr.summary(npc)
    if not npc.traumas then return "" end
    local parts = {}
    for kind, rec in pairs(npc.traumas) do
        local def = Tr.KINDS[kind]
        parts[#parts + 1] = (def and def.fi or kind) ..
            (rec.count > 1 and (" x" .. rec.count) or "")
    end
    table.sort(parts)
    return table.concat(parts, ", ")
end

return Tr
