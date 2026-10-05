-- Group-to-group standing and personal relationships.
--
-- Thresholds from the guide:
--   BLOOD_FEUD <= -0.85
--   HOSTILE    > -0.85 .. <= -0.35
--   SUSPICIOUS > -0.35 .. <  -0.10
--   NEUTRAL    >= -0.10 .. <   0.55
--   FRIENDLY   >=  0.55
local U = require("core.util")
local Tr = require("npc.trauma")

local D = {}

D.TIERS = {
    { key = "BLOOD_FEUD", fi = "Verivihollisuus", max = -0.85 },
    { key = "HOSTILE",    fi = "Vihamielinen",    max = -0.35 },
    { key = "SUSPICIOUS", fi = "Epaluuloinen",    max = -0.10 },
    { key = "NEUTRAL",    fi = "Neutraali",       max = 0.55 },
    { key = "FRIENDLY",   fi = "Ystavallinen",    max = 1.01 },
}

-- Default standings: see D.default_standing (everyone hostile).
D.BANDIT_VS_AUTHORITY = -0.80
D.BANDIT_VS_OTHER = -0.65

local AUTHORITY = {
    police_patrol = true, military_group = true, elite_unit = true,
}

function D.tier(value)
    value = U.clamp(value or 0, -1, 1)
    if value <= -0.85 then return "BLOOD_FEUD", "Verivihollisuus" end
    for i = 2, #D.TIERS do
        if value < D.TIERS[i].max then return D.TIERS[i].key, D.TIERS[i].fi end
    end
    return "FRIENDLY", "Ystavallinen"
end

-- Standings the owner's own classes bring (ryhmat.lua: vihamieliset,
-- viranomainen).
local custom_pairs = {}
function D.set_default(class_a, class_b, value)
    custom_pairs[class_a .. "|" .. class_b] = value
    custom_pairs[class_b .. "|" .. class_a] = value
end
function D.add_authority(class_key) AUTHORITY[class_key] = true end

-- Every squad is hostile to every other squad, whatever their classes (the
-- owner's rule: only the members of one squad are friends). Bandits and the authorities hate each other most. The
-- owner's own class pairs (ryhmat.lua) still set their own standing.
D.ALL_HOSTILE = -0.65
D.ZONE_ALLIES = { radiation_group = true, island_residents = true }
function D.default_standing(class_a, class_b)
    local c = custom_pairs[class_a .. "|" .. class_b]
    if c then return c end
    -- The squads of a closed zone stick together: the radiation teams in C0
    -- and the islanders on Z4 are friends among themselves.
    if class_a == class_b and D.ZONE_ALLIES[class_a] then return 0.6 end
    if class_a == "bandit_gang" or class_b == "bandit_gang" then
        local other = (class_a == "bandit_gang") and class_b or class_a
        if AUTHORITY[other] then return D.BANDIT_VS_AUTHORITY end
    end
    return D.ALL_HOSTILE
end

local function key_of(a, b)
    if a < b then return a .. "|" .. b end
    return b .. "|" .. a
end

-- Registry of live standings, keyed by group id pair.
function D.new_registry()
    return { pairs = {} }
end

-- Only standings that differ from the default are stored. 2.0.3 stored
-- every pair it ever looked up, wiped squads included: after a few days the
-- saved world was 9.6 MB of pairs and every save froze the server for 5 s.
function D.standing(reg, ga, gb)
    if not (ga and gb) or ga.gid == gb.gid then return 1.0 end
    local v = reg.pairs[key_of(ga.gid, gb.gid)]
    if v == nil then v = D.default_standing(ga.class, gb.class) end
    return v
end

function D.adjust(reg, ga, gb, delta, reason)
    if not (ga and gb) or ga.gid == gb.gid then return 0 end
    local k = key_of(ga.gid, gb.gid)
    local cur = D.standing(reg, ga, gb)
    local nv = U.clamp(cur + delta, -1, 1)
    if math.abs(nv - D.default_standing(ga.class, gb.class)) < 0.001 then
        reg.pairs[k] = nil
    else
        reg.pairs[k] = nv
    end
    reg.last_reason = reason
    return nv
end

-- Drops the standings of squads that no longer exist (and any default
-- values an older save stored). Returns how many were dropped.
function D.prune(reg, groups)
    local class_of = {}
    for _, g in ipairs(groups or {}) do
        if g.gid then class_of[g.gid] = g.class end
    end
    local dropped = 0
    for k, v in pairs(reg.pairs) do
        local a, b = k:match("^(.-)|(.*)$")
        local ca, cb = a and class_of[a], b and class_of[b]
        if not (ca and cb) or type(v) ~= "number"
            or math.abs(v - D.default_standing(ca, cb)) < 0.001 then
            reg.pairs[k] = nil
            dropped = dropped + 1
        end
    end
    return dropped
end

function D.hostile(reg, ga, gb)
    local v = D.standing(reg, ga, gb)
    local tier = D.tier(v)
    return tier == "HOSTILE" or tier == "BLOOD_FEUD", v, tier
end

-- ------------------------------------------------------ personal relations --

-- Inside a group, relationships drift up slowly with loyalty, sociability,
-- teamwork and cohesion, as the guide describes.
function D.tick_relations(group, dt)
    local members = group.members
    if not members or #members < 2 then return end
    local cohesion = group.cohesion or 0.7
    for i = 1, #members do
        local a = members[i]
        if a.alive then
            a.relations = a.relations or {}
            for j = 1, #members do
                local b = members[j]
                if i ~= j and b.alive then
                    local cur = a.relations[b.npcId] or 0
                    local rate = (Tr.trait(a, "loyalty") * 0.35 +
                                  Tr.trait(a, "sociability") * 0.30 +
                                  Tr.trait(a, "teamwork") * 0.35)
                    local drift = (rate * cohesion - 0.30) * 0.00035 * dt
                    a.relations[b.npcId] = U.clamp(cur + drift, -1, 1)
                end
            end
        end
    end
end

-- Auto-grouping compatibility: bandits do not mix with other backgrounds.
local FAMILY = {
    civilian = "civil", scavenger = "civil", survivor = "civil", hunter = "civil",
    bandit = "bandit",
    police = "order", security = "order", militia = "order",
    ex_military = "military", veteran = "military",
    bunker_specialist = "military", elite = "military",
    radiation_specialist = "special",
}

function D.family(archetype) return FAMILY[archetype] or "civil" end

function D.compatible(a, b)
    local fa, fb = D.family(a.archetype), D.family(b.archetype)
    if fa == "bandit" or fb == "bandit" then return fa == fb end
    return true
end

return D
