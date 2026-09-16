-- SmartNPC :: traits.lua
-- Per-NPC personality and per-squad archetype.
--
-- Traits are deterministic per NPC identity, so a squad keeps its character
-- across a virtual/physical handover and across a server restart.

local S = SMARTNPC
local U = S.util

local T = {}

--------------------------------------------------------------------------
-- archetypes
--------------------------------------------------------------------------

T.ARCHETYPES = {
    {
        id = "RAIDERS", label = "Raiders", colour = "#e2574c",
        weight = 20,
        activity = { LOOT_RUN = 34, SCAVENGE = 20, HUNT = 4, PATROL = 12, CAMP = 8, AMBUSH = 22 },
        bias = { aggression = 0.78, caution = 0.30, greed = 0.80, discipline = 0.45, stamina = 0.65 },
        size = { 3, 6 },
        gait = "jog",
    },
    {
        id = "SCAVENGERS", label = "Scavengers", colour = "#e0a63c",
        weight = 26,
        activity = { LOOT_RUN = 24, SCAVENGE = 44, HUNT = 8, PATROL = 6, CAMP = 14, AMBUSH = 4 },
        bias = { aggression = 0.32, caution = 0.72, greed = 0.85, discipline = 0.40, stamina = 0.50 },
        size = { 2, 4 },
        gait = "walk",
    },
    {
        id = "HUNTERS", label = "Hunters", colour = "#6bbf59",
        weight = 16,
        activity = { LOOT_RUN = 8, SCAVENGE = 14, HUNT = 46, PATROL = 10, CAMP = 18, AMBUSH = 4 },
        bias = { aggression = 0.45, caution = 0.62, greed = 0.35, discipline = 0.55, stamina = 0.80 },
        size = { 2, 4 },
        gait = "walk",
    },
    {
        id = "PATROL", label = "Patrol", colour = "#4a9ad4",
        weight = 18,
        activity = { LOOT_RUN = 10, SCAVENGE = 12, HUNT = 4, PATROL = 52, CAMP = 14, AMBUSH = 8 },
        bias = { aggression = 0.55, caution = 0.55, greed = 0.25, discipline = 0.85, stamina = 0.70 },
        size = { 3, 5 },
        gait = "walk",
    },
    {
        id = "MILITIA", label = "Militia", colour = "#9b6bd4",
        weight = 12,
        activity = { LOOT_RUN = 22, SCAVENGE = 16, HUNT = 6, PATROL = 30, CAMP = 12, AMBUSH = 14 },
        bias = { aggression = 0.70, caution = 0.48, greed = 0.45, discipline = 0.78, stamina = 0.72 },
        size = { 4, 6 },
        gait = "jog",
    },
    {
        id = "LONER", label = "Loner", colour = "#8c8c8c",
        weight = 8,
        activity = { LOOT_RUN = 26, SCAVENGE = 30, HUNT = 22, PATROL = 6, CAMP = 12, AMBUSH = 4 },
        bias = { aggression = 0.35, caution = 0.88, greed = 0.60, discipline = 0.30, stamina = 0.55 },
        size = { 1, 1 },
        gait = "walk",
    },
}

function T.pick_archetype()
    return U.pick_weighted(T.ARCHETYPES, function(a) return a.weight end)
end

function T.archetype(id)
    for _, a in ipairs(T.ARCHETYPES) do if a.id == id then return a end end
    return T.ARCHETYPES[1]
end

--------------------------------------------------------------------------
-- individual traits
--------------------------------------------------------------------------

local TRAIT_NAMES = {
    "aggression",   -- willingness to start and press a fight
    "caution",      -- distance kept, tendency to break contact
    "greed",        -- pull toward loot-dense sites
    "discipline",   -- formation tightness, stop punctuality
    "stamina",      -- how long it can jog/sprint
    "marksmanship", -- preferred engagement range
    "curiosity",    -- side trips, looking around
    "loyalty",      -- how far it strays from the squad
}
T.NAMES = TRAIT_NAMES

-- Deterministic roll around the archetype bias.
function T.roll(identity, archetype)
    local t = {}
    for i, name in ipairs(TRAIT_NAMES) do
        local base = (archetype.bias and archetype.bias[name]) or 0.5
        local jitter = (U.hash01(identity, "trait" .. i) - 0.5) * 0.44
        t[name] = U.clamp(base + jitter, 0.03, 0.99)
    end
    -- Derived, cached so the hot path never recomputes them.
    t.speed_mul     = 0.93 + t.stamina * 0.16
    t.engage_range  = 500 + t.marksmanship * 1800
    t.retreat_hp    = 18 + (1 - t.aggression) * 34
    t.stop_mul      = 0.7 + t.curiosity * 0.9
    t.slot_spread   = 1.35 - t.discipline * 0.5
    return t
end

-- A readable one-line description used by the map UI.
function T.describe(t)
    local strong, weak = nil, nil
    local hi, lo = -1, 2
    for _, name in ipairs(TRAIT_NAMES) do
        local v = t[name] or 0.5
        if v > hi then hi, strong = v, name end
        if v < lo then lo, weak = v, name end
    end
    return strong .. "+/" .. weak .. "-"
end

--------------------------------------------------------------------------
-- squad names
--------------------------------------------------------------------------

local FIRST = {
    "Grey", "Iron", "Black", "Red", "Rust", "Ash", "Cold", "Silent", "Broken",
    "Low", "Long", "Dead", "Bitter", "Salt", "Pale", "Night", "Storm", "Dry",
}
local SECOND = {
    "Wolves", "Hounds", "Crows", "Nomads", "Vultures", "Jackals", "Ravens",
    "Wardens", "Drifters", "Foxes", "Bears", "Vipers", "Hawks", "Rats",
    "Boars", "Lions", "Moths", "Coyotes",
}

function T.squad_name(seed)
    local a = FIRST[(U.hash(tostring(seed) .. "a") % #FIRST) + 1]
    local b = SECOND[(U.hash(tostring(seed) .. "b") % #SECOND) + 1]
    local n = (U.hash(tostring(seed) .. "n") % 89) + 10
    return a .. " " .. b .. " " .. n
end

return T
