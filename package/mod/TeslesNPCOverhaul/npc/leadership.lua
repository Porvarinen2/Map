-- Leader selection and succession.
--
-- A leader earns the role by score: leadership trait and skill, discipline,
-- courage, decision confidence, loyalty, and the trust the other members
-- place in them. Stress lowers the score, so the highest level member is not
-- automatically in charge.
local U = require("core.util")
local Tr = require("npc.trauma")

local L = {}

-- Succession delay by group level: 5.75 s at level 1 up to 8.75 s at level 5.
L.SUCCESSION_BASE = 5.75
L.SUCCESSION_PER_LEVEL = 0.75

function L.succession_delay(level)
    level = math.max(1, math.min(5, level or 1))
    return L.SUCCESSION_BASE + (level - 1) * L.SUCCESSION_PER_LEVEL
end

function L.score(npc, group)
    if not npc or not npc.alive then return -1 end
    local t = function(k) return Tr.trait(npc, k) end
    local s = npc.skills or {}
    local score =
        t("leadership") * 0.26 +
        (s.leadership or 0) * 0.18 +
        t("discipline") * 0.14 +
        t("courage") * 0.11 +
        t("decisionConfidence") * 0.13 +
        t("loyalty") * 0.07 +
        (npc.level or 1) / 5 * 0.11

    -- Trust from the rest of the group.
    if group and group.members then
        local sum, n = 0, 0
        for _, m in ipairs(group.members) do
            if m ~= npc and m.alive then
                local rel = (npc.relations and npc.relations[m.npcId]) or 0
                sum = sum + rel
                n = n + 1
            end
        end
        if n > 0 then score = score + U.clamp(sum / n, -1, 1) * 0.09 end
    end

    score = score - (npc.stress or 0) * 0.20
    return score
end

-- Picks the best candidate. Returns npc, score.
function L.select(group)
    if not group or not group.members then return nil end
    local best, best_score = nil, -math.huge
    for _, m in ipairs(group.members) do
        if m.alive then
            local sc = L.score(m, group)
            if sc > best_score then best, best_score = m, sc end
        end
    end
    return best, best_score
end

function L.leader(group)
    if not group or not group.leader_id then return nil end
    for _, m in ipairs(group.members) do
        if m.npcId == group.leader_id and m.alive then return m end
    end
    return nil
end

function L.assign(group, npc)
    for _, m in ipairs(group.members) do m.is_leader = false end
    if npc then
        npc.is_leader = true
        group.leader_id = npc.npcId
        group.leader_lost_at = nil
        group.leaderless = false
    else
        group.leader_id = nil
        group.leaderless = true
    end
    return npc
end

-- Called when the leader dies. Morale and cohesion drop, survivors remember.
function L.on_leader_lost(group, now, on_member)
    group.leader_id = nil
    group.leaderless = true
    group.leader_lost_at = now
    group.leader_ready_at = now + L.succession_delay(group.level)
    group.morale = U.clamp((group.morale or 0.6) - 0.28, 0, 1)
    group.cohesion = U.clamp((group.cohesion or 0.7) - 0.24, 0, 1)
    for _, m in ipairs(group.members) do
        if m.alive and on_member then on_member(m) end
    end
end

function L.on_leader_wounded(group)
    group.morale = U.clamp((group.morale or 0.6) - 0.10, 0, 1)
    group.cohesion = U.clamp((group.cohesion or 0.7) - 0.08, 0, 1)
end

-- Ready to promote a successor?
function L.succession_due(group, now)
    return group.leaderless and group.leader_ready_at and now >= group.leader_ready_at
end

-- A calm, alive leader slowly restores group morale and cohesion, up to the
-- ceiling that leader actually earns. A mediocre leader never gets a squad to
-- perfect morale, which keeps groups distinguishable over a long session.
function L.recover(group, dt)
    local lead = L.leader(group)
    if not lead then return end
    local quality = Tr.trait(lead, "leadership") * 0.5
        + (lead.skills and lead.skills.leadership or 0) * 0.3
        + Tr.trait(lead, "composure") * 0.2
    local calm = (1 - (lead.stress or 0))
    local ceiling = U.clamp(0.48 + quality * 0.45, 0, 0.95)
    local rate = quality * calm * 0.0045
    local m = group.morale or 0.6
    if m < ceiling then group.morale = math.min(ceiling, m + rate * dt) end
    local c = group.cohesion or 0.7
    local c_ceiling = U.clamp(0.45 + quality * 0.50, 0, 0.95)
    if c < c_ceiling then group.cohesion = math.min(c_ceiling, c + rate * 0.8 * dt) end
end

-- Leader's standing order, weighted by group morale. Below 0.25 morale the
-- order flips from attacking to withdrawing, as the guide specifies.
function L.order(group, threat)
    local lead = L.leader(group)
    if not lead then return "NONE", 0 end
    local morale = group.morale or 0.6
    local weight = (Tr.trait(lead, "leadership") * 0.5 +
                    (lead.skills and lead.skills.leadership or 0) * 0.5)
    if morale < 0.25 then return "RETREAT", weight end
    if threat then
        if Tr.trait(lead, "aggression") > 0.55 and morale > 0.45 then
            return "ATTACK", weight
        end
        return "COVER", weight
    end
    return "ADVANCE", weight * 0.5
end

return L
