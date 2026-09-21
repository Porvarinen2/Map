-- Action selection.
--
-- Seven scored actions from the guide: ATTACK, COVER, RETREAT, FLANK,
-- INVESTIGATE, HELP_FRIEND, FLEE. Scores combine personality, stress, the
-- balance of power, zombie pressure and the leader's standing order. A new
-- action must beat the current one by SWITCH_MARGIN before it is adopted,
-- which is what stops decisions flip-flopping every tick.
local U = require("core.util")
local Tr = require("npc.trauma")

local Ut = {}

Ut.SWITCH_MARGIN = 0.12

Ut.ACTIONS = {
    { key = "ATTACK",      fi = "Hyokkaa" },
    { key = "COVER",       fi = "Suojaudu" },
    { key = "RETREAT",     fi = "Vetaydy" },
    { key = "FLANK",       fi = "Koukkaa" },
    { key = "INVESTIGATE", fi = "Tutki" },
    { key = "HELP_FRIEND", fi = "Auta" },
    { key = "FLEE",        fi = "Pakene" },
}

Ut.fi = {}
for _, a in ipairs(Ut.ACTIONS) do Ut.fi[a.key] = a.fi end

-- ctx fields (all optional):
--   threat            true when a hostile is known
--   threat_distance   UU
--   power_ratio       own group power / enemy power (1 = even)
--   zombie_pressure   0..1
--   friend_down       true when a group mate needs help
--   cover_available   0..1
--   order             leader order key
--   order_weight      0..1 influence of that order
--   unknown_contact   true when something was heard/seen but not identified
function Ut.score(npc, ctx)
    ctx = ctx or {}
    local t = function(k) return Tr.trait(npc, k) end
    local s = npc.skills or {}
    local stress = npc.stress or 0
    local calm = 1 - stress
    local power = U.clamp(ctx.power_ratio or 1.0, 0.1, 3.0)
    local zeds = U.clamp(ctx.zombie_pressure or 0, 0, 1)
    local out = {}

    -- ATTACK: aggression, courage, combat confidence, low stress.
    out.ATTACK = (t("aggression") * 0.34 + t("courage") * 0.26
        + t("combatConfidence") * 0.26 + calm * 0.14)
        * (ctx.threat and 1.0 or 0.05)
        * U.clamp(0.55 + power * 0.45, 0.2, 1.6)

    -- COVER: cautiousness, discipline and stress, helped by real cover.
    out.COVER = (t("cautiousness") * 0.32 + t("discipline") * 0.26
        + stress * 0.24 + (ctx.cover_available or 0.5) * 0.18)
        * (ctx.threat and 1.0 or 0.06)

    -- RETREAT: fear, survival instinct, stress, being outgunned.
    out.RETREAT = (t("fearfulness") * 0.26 + t("survivalInstinct") * 0.28
        + stress * 0.24 + U.clamp(1.4 - power, 0, 1.2) * 0.22)
        * (ctx.threat and 1.0 or 0.04)

    -- FLANK: tactical skill, discipline, courage, low stress.
    out.FLANK = ((s.tacticalMovement or 0) * 0.34 + t("discipline") * 0.24
        + t("courage") * 0.22 + calm * 0.20)
        * (ctx.threat and 1.0 or 0.02)
        * U.clamp(0.4 + power * 0.6, 0.2, 1.4)

    -- INVESTIGATE: curiosity and awareness, held back by caution.
    out.INVESTIGATE = (t("curiosity") * 0.40 + t("awareness") * 0.32
        - t("cautiousness") * 0.22 + 0.22)
        * (ctx.unknown_contact and 1.0 or (ctx.threat and 0.10 or 0.30))

    -- HELP_FRIEND: empathy, loyalty, protectiveness.
    out.HELP_FRIEND = (t("empathy") * 0.36 + t("loyalty") * 0.32
        + t("protectiveness") * 0.32)
        * (ctx.friend_down and 1.0 or 0.02)

    -- FLEE: the retreat drivers plus fear and heavy zombie pressure.
    out.FLEE = (t("fearfulness") * 0.34 + t("survivalInstinct") * 0.22
        + stress * 0.24 + zeds * 0.30)
        * ((ctx.threat or zeds > 0.3) and 1.0 or 0.02)
        * U.clamp(1.6 - power, 0.2, 1.8)

    -- The leader's order tilts the scoring; obedience decides how much.
    if ctx.order and ctx.order ~= "NONE" and out[ctx.order] then
        local pull = (ctx.order_weight or 0.5) * t("obedience") * 0.42
        out[ctx.order] = out[ctx.order] * (1 + pull)
    end

    for k, v in pairs(out) do out[k] = U.clamp(v, 0, 3) end
    return out
end

-- Picks the action, honouring the switch margin against the current one.
-- Returns action, score, scores table, switched.
function Ut.decide(npc, ctx)
    local scores = Ut.score(npc, ctx)
    local best, best_score = nil, -math.huge
    for k, v in pairs(scores) do
        if v > best_score then best, best_score = k, v end
    end
    local current = npc.action
    if current and scores[current] then
        if best ~= current and best_score < scores[current] + Ut.SWITCH_MARGIN then
            return current, scores[current], scores, false
        end
    end
    local switched = (best ~= current)
    npc.action = best
    npc.action_score = best_score
    if switched then npc.action_since = os.time() end
    return best, best_score, scores, switched
end

-- Group power: alive members weighted by rifle and tactical skill, reduced by
-- stress, lifted by cohesion. Used for the power ratio above.
function Ut.group_power(group)
    if not group or not group.members then return 0 end
    local power = 0
    local alive = 0
    for _, m in ipairs(group.members) do
        if m.alive then
            alive = alive + 1
            local s = m.skills or {}
            local skill = (s.rifle or 0) * 0.45 + (s.tacticalMovement or 0) * 0.30
                + (s.coverUse or 0) * 0.25
            local hp = U.clamp((m.health or 100) / 100, 0, 1)
            power = power + (0.45 + skill * 0.55) * hp * (1 - (m.stress or 0) * 0.35)
        end
    end
    if alive == 0 then return 0 end
    return power * (0.75 + (group.cohesion or 0.7) * 0.35)
end

return Ut
