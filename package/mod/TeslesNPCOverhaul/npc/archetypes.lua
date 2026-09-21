-- The 13 character archetypes from the NPC guide.
--
-- `traits` and `skills` are offsets applied on top of the neutral 0.5 trait
-- baseline and the level base skill value. An archetype shifts probabilities;
-- it does not script a character. A brave civilian and a timid bandit both
-- remain possible.
local A = {}

A.list = {
    {
        key = "civilian", fi = "Siviili", levels = { 1, 2 },
        traits = { discipline = -0.18, stressResistance = -0.16, combatConfidence = -0.20,
                   courage = -0.12, fearfulness = 0.14, teamwork = -0.05 },
        skills = { rifle = -0.12, coverUse = -0.10, tacticalMovement = -0.12, melee = -0.04 },
    },
    {
        key = "scavenger", fi = "Keräilijä", levels = { 1, 3 },
        traits = { greed = 0.26, curiosity = 0.20, resourcefulness = 0.18,
                   cautiousness = 0.08, explorationDrive = 0.16 },
        skills = { survival = 0.10, navigation = 0.10, stealth = 0.04 },
    },
    {
        key = "survivor", fi = "Selviytyjä", levels = { 1, 4 },
        traits = { survivalInstinct = 0.22, adaptability = 0.18, resourcefulness = 0.14,
                   persistence = 0.10 },
        skills = { survival = 0.12, navigation = 0.08, firstAid = 0.05 },
    },
    {
        key = "hunter", fi = "Metsästäjä", levels = { 2, 4 },
        traits = { patience = 0.22, awareness = 0.20, cautiousness = 0.14,
                   stealthPreference = 0.24, aggression = -0.05 },
        skills = { rifle = 0.12, perception = 0.14, stealth = 0.14, navigation = 0.10 },
    },
    {
        key = "bandit", fi = "Rosvo", levels = { 1, 4 },
        traits = { aggression = 0.24, greed = 0.22, mercy = -0.26, riskTolerance = 0.14,
                   territoriality = 0.12, vindictiveness = 0.12 },
        skills = { rifle = 0.05, pistol = 0.05, melee = 0.08 },
    },
    {
        key = "police", fi = "Poliisi", levels = { 2, 4 },
        traits = { discipline = 0.22, teamwork = 0.18, courage = 0.14,
                   stressResistance = 0.16, obedience = 0.12 },
        skills = { pistol = 0.14, tacticalMovement = 0.12, coverUse = 0.12 },
    },
    {
        key = "security", fi = "Vartija", levels = { 2, 4 },
        traits = { discipline = 0.18, cautiousness = 0.16, territoriality = 0.22,
                   awareness = 0.10 },
        skills = { pistol = 0.10, coverUse = 0.12, perception = 0.12 },
    },
    {
        key = "militia", fi = "Miliisi", levels = { 2, 4 },
        traits = { aggression = 0.14, teamwork = 0.16, territoriality = 0.20,
                   courage = 0.08 },
        skills = { rifle = 0.10, tacticalMovement = 0.08, coverUse = 0.08 },
    },
    {
        key = "ex_military", fi = "Entinen sotilas", levels = { 3, 5 },
        traits = { discipline = 0.26, courage = 0.20, stressResistance = 0.22,
                   teamwork = 0.20, composure = 0.18 },
        skills = { tacticalMovement = 0.18, coverUse = 0.18, rifle = 0.10,
                   leadership = 0.08, navigation = 0.08, firstAid = 0.08 },
    },
    {
        key = "veteran", fi = "Veteraani", levels = { 3, 5 },
        traits = { stressResistance = 0.22, combatConfidence = 0.22, composure = 0.20,
                   awareness = 0.16, courage = 0.14 },
        skills = { rifle = 0.16, tacticalMovement = 0.14, coverUse = 0.14,
                   perception = 0.10 },
    },
    {
        key = "radiation_specialist", fi = "Säteilyalueen erikoisosaaja", levels = { 2, 5 },
        traits = { cautiousness = 0.24, discipline = 0.18, stressResistance = 0.12 },
        skills = { survival = 0.18, navigation = 0.16, firstAid = 0.14 },
    },
    {
        key = "bunker_specialist", fi = "Bunkkeriasiantuntija", levels = { 3, 5 },
        traits = { discipline = 0.20, cautiousness = 0.20, awareness = 0.18 },
        skills = { shotgun = 0.18, pistol = 0.14, tacticalMovement = 0.14,
                   perception = 0.14 },
    },
    {
        key = "elite", fi = "Eliittitaistelija", levels = { 5, 5 },
        traits = { discipline = 0.30, stressResistance = 0.30, teamwork = 0.28,
                   composure = 0.28, decisionConfidence = 0.26, courage = 0.22,
                   combatConfidence = 0.24 },
        skills = { rifle = 0.18, pistol = 0.14, tacticalMovement = 0.20,
                   coverUse = 0.20, perception = 0.16, leadership = 0.10 },
    },
}

A.by_key = {}
for _, a in ipairs(A.list) do A.by_key[a.key] = a end
A.count = #A.list

function A.get(key) return A.by_key[key] end

function A.level_range(key)
    local a = A.by_key[key]
    if not a then return 1, 3 end
    return a.levels[1], a.levels[2]
end

return A
