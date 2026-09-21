-- Stress model from the guide.
-- States: calm < 0.20, alert 0.20-0.39, stressed 0.40-0.59,
--         high 0.60-0.79, panic >= 0.80.
local U = require("core.util")

local St = {}

St.STATES = {
    { key = "CALM",     fi = "Rauhallinen",              max = 0.20 },
    { key = "ALERT",    fi = "Valpas",                   max = 0.40 },
    { key = "STRESSED", fi = "Stressaantunut",           max = 0.60 },
    { key = "HIGH",     fi = "Voimakkaasti stressaantunut", max = 0.80 },
    { key = "PANIC",    fi = "Paniikki",                 max = 1.01 },
}

-- Base stress deltas per event. stressResistance scales the increase and the
-- recovery rate, per the guide.
St.EVENTS = {
    GUNSHOT_NEAR      = 0.16,
    GUNSHOT_DISTANT   = 0.05,
    EXPLOSION         = 0.24,
    NEAR_MISS         = 0.22,
    INJURY            = 0.20,
    SEVERE_INJURY     = 0.34,
    ALLY_DOWN         = 0.26,
    LEADER_DOWN       = 0.32,
    LEADER_WOUNDED    = 0.14,
    ZOMBIE_CONTACT    = 0.12,
    ZOMBIE_HORDE      = 0.26,
    OUTNUMBERED       = 0.15,
    DARKNESS          = 0.04,
    HUNGER            = 0.05,
    THIRST            = 0.05,
    ENEMY_SPOTTED     = 0.09,
    AMBUSHED          = 0.30,
}

function St.state_of(stress)
    stress = U.clamp(stress or 0, 0, 1)
    for _, s in ipairs(St.STATES) do
        if stress < s.max then return s.key, s.fi end
    end
    return "PANIC", "Paniikki"
end

-- Applies a named stress event to one NPC.
function St.apply(npc, event, scale)
    local base = St.EVENTS[event]
    if not base then return 0 end
    local resist = npc.traits and npc.traits.stressResistance or 0.5
    local composure = npc.traits and npc.traits.composure or 0.5
    local fear = npc.traits and npc.traits.fearfulness or 0.5
    -- Resistance dampens; fearfulness amplifies.
    local factor = (1.25 - resist * 0.75) * (0.82 + fear * 0.36)
    local delta = base * factor * (scale or 1)
    local before = npc.stress or 0
    npc.stress = U.clamp(before + delta, 0, 1)
    npc.last_stress_event = event
    -- Composure keeps morale from collapsing on a single shock.
    npc.morale = U.clamp((npc.morale or 0.6) - delta * (0.55 - composure * 0.3), 0, 1)
    return npc.stress - before
end

-- Resting stress level. Nobody in this world is perfectly calm: an anxious,
-- paranoid survivor settles noticeably higher than a veteran, which is what
-- makes two NPCs in the same situation react differently.
function St.baseline(npc)
    local t = npc.traits or {}
    return U.clamp(0.03
        + (t.fearfulness or 0.5) * 0.17
        + (t.paranoia or 0.5) * 0.09
        - (t.stressResistance or 0.5) * 0.06, 0, 0.35)
end

-- Per-second recovery towards that baseline. Composure and stress resistance
-- both speed it up; danger nearly stops it.
function St.recover(npc, dt, in_danger)
    if not npc or not npc.alive then return end
    local resist = npc.traits and npc.traits.stressResistance or 0.5
    local composure = npc.traits and npc.traits.composure or 0.5
    local floor = St.baseline(npc)
    local rate = (0.0045 + resist * 0.0055 + composure * 0.0040)
    if in_danger then rate = rate * 0.18 end
    local cur = npc.stress or 0
    if cur > floor then
        npc.stress = math.max(floor, cur - rate * dt)
    elseif cur < floor and not in_danger then
        npc.stress = math.min(floor, cur + rate * 0.35 * dt)
    end
    -- Morale settles at a personal ceiling rather than pinning at 1.
    local ceiling = U.clamp(0.55 + composure * 0.22 + resist * 0.18, 0, 0.95)
    local morale_rate = 0.0030 + composure * 0.0035
    if in_danger then morale_rate = morale_rate * 0.25 end
    local m = npc.morale or 0.6
    if m < ceiling then npc.morale = math.min(ceiling, m + morale_rate * dt) end
end

-- Hunger and thirst from the guide's stress event list. Applied by the
-- director as a group's abstract supply runs down.
function St.privation(npc, supply, dt)
    if not npc or not npc.alive then return end
    if supply >= 40 then return end
    local severity = (40 - supply) / 40
    local resist = npc.traits and npc.traits.stressResistance or 0.5
    npc.stress = U.clamp((npc.stress or 0)
        + 0.0009 * severity * (1.3 - resist * 0.6) * dt, 0, 1)
end

function St.group_stress(group)
    if not group or #group.members == 0 then return 0 end
    local sum, n = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then sum = sum + (m.stress or 0); n = n + 1 end
    end
    if n == 0 then return 1 end
    return sum / n
end

return St
