-- The 12 NPC skills and the five skill levels from the guide.
-- Level base values: 0.08 / 0.26 / 0.44 / 0.62 / 0.80, plus archetype weighting
-- and individual variation, clamped to 0..1.
local S = {}

S.list = {
    { key = "rifle",            fi = "Kivaari",            group = "weapons" },
    { key = "pistol",           fi = "Pistooli",           group = "weapons" },
    { key = "shotgun",          fi = "Haulikko",           group = "weapons" },
    { key = "melee",            fi = "Lahitaistelu",       group = "weapons" },
    { key = "tacticalMovement", fi = "Taktinen liike",     group = "movement" },
    { key = "coverUse",         fi = "Suojankaytto",       group = "movement" },
    { key = "navigation",       fi = "Navigointi",         group = "movement" },
    { key = "perception",       fi = "Havainnointi",       group = "movement" },
    { key = "stealth",          fi = "Hiiviskely",         group = "movement" },
    { key = "leadership",       fi = "Johtaminen",         group = "support" },
    { key = "firstAid",         fi = "Ensiapu",            group = "support" },
    { key = "survival",         fi = "Selviytyminen",      group = "support" },
}

S.keys = {}
for i, s in ipairs(S.list) do S.keys[i] = s.key end
S.count = #S.list

S.level_base = { 0.08, 0.26, 0.44, 0.62, 0.80 }
S.level_name = { "Aloittelija", "Kokematon", "Kokenut", "Taitava", "Eliitti" }

function S.base_for(level)
    return S.level_base[math.max(1, math.min(5, math.floor(level or 1)))] or 0.08
end

-- Rounded mean member level, as the guide specifies for group level.
function S.group_level(members)
    if not members or #members == 0 then return 1 end
    local sum = 0
    for _, m in ipairs(members) do sum = sum + (m.level or 1) end
    return math.max(1, math.min(5, math.floor(sum / #members + 0.5)))
end

return S
