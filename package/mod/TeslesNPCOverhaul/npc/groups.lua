-- The 13 group classes from the NPC guide.
--
-- `poi_weights` are relative selection weights over the kinds on the
-- hand-marked map (world/poi_data.lua), not percentages. A kind that is not
-- listed is never chosen: a bunker group has no business at a hunting tower. `tactics` is a classification label used by the live map and by
-- combat scoring; it is not a claim of a separate finished algorithm.
local G = {}

G.list = {
    {
        key = "lone_wanderer", fi = "Yksinäinen kulkija", size = { 1, 1 },
        archetypes = { "survivor", "hunter", "scavenger", "veteran" },
        tactics = "solo", weight = 12,
        poi_weights = { VILLAGE = 3.0, HUNTING = 2.4, LANDMARK = 1.6, INDUSTRIAL = 1.2, CITY = 1.0, MEDICAL = 1.0 },
    },
    {
        key = "pair", fi = "Kaksikko", size = { 2, 2 },
        archetypes = { "survivor", "hunter", "police", "ex_military" },
        tactics = "paired", weight = 12,
        poi_weights = { VILLAGE = 3.0, HUNTING = 2.0, CITY = 1.6, LANDMARK = 1.4, INDUSTRIAL = 1.2, MEDICAL = 1.0 },
    },
    {
        key = "hunters", fi = "Metsästäjät", size = { 2, 4 },
        archetypes = { "hunter", "survivor" },
        tactics = "patient", weight = 10,
        poi_weights = { HUNTING = 6.0, VILLAGE = 1.4, LANDMARK = 1.2 },
    },
    {
        key = "scavengers", fi = "Keräilijät", size = { 2, 5 },
        archetypes = { "scavenger", "survivor", "bandit" },
        tactics = "opportunist", weight = 14,
        poi_weights = { VILLAGE = 4.0, CITY = 3.0, INDUSTRIAL = 3.0, MEDICAL = 1.6, LANDMARK = 1.0 },
    },
    {
        key = "police_patrol", fi = "Poliisipartio", size = { 2, 4 },
        archetypes = { "police", "security" },
        tactics = "disciplined", weight = 8,
        poi_weights = { CITY = 5.0, VILLAGE = 3.2, MEDICAL = 1.8, INDUSTRIAL = 1.0, MILITARY = 0.8 },
    },
    {
        key = "military_group", fi = "Sotilastaustainen ryhmä", size = { 3, 5 },
        archetypes = { "ex_military", "veteran", "bunker_specialist" },
        tactics = "military", weight = 7,
        poi_weights = { MILITARY = 5.0, BUNKER = 3.0, ABANDONED_BUNKER = 2.4, RESEARCH = 2.0, INDUSTRIAL = 1.2 },
    },
    {
        key = "radiation_group", fi = "Säteilyryhmä", size = { 2, 5 },
        archetypes = { "radiation_specialist" },
        tactics = "hazmat", weight = 3, reserved_zone = "C0",
        -- Krsko (swept area by area), the nuclear power plant, the camp below
        -- it, round and round. Two places of memory make that the only walk.
        poi_weights = { CITY = 3.0, INDUSTRIAL = 3.0, LANDMARK = 2.0 },
        circuit = { "CIT_C0_01", "IND_C0_01", "LAN_C0_01" },
        memory = 2,
    },
    {
        key = "bunker_group", fi = "Bunkkeriryhmä", size = { 2, 5 },
        archetypes = { "bunker_specialist", "ex_military", "security" },
        tactics = "close_quarters", weight = 5,
        poi_weights = { BUNKER = 6.0, ABANDONED_BUNKER = 5.0, RESEARCH = 4.0, MILITARY = 3.5 },
    },
    {
        key = "bandit_gang", fi = "Rosvojoukko", size = { 2, 5 },
        archetypes = { "bandit", "scavenger" },
        tactics = "aggressive", weight = 11,
        poi_weights = { VILLAGE = 4.0, CITY = 2.6, INDUSTRIAL = 2.2, LANDMARK = 1.2, MILITARY = 1.0 },
    },
    {
        key = "survivor_group", fi = "Selviytyjäryhmä", size = { 2, 5 },
        archetypes = { "survivor", "civilian", "scavenger", "hunter" },
        tactics = "mixed", weight = 13,
        poi_weights = { VILLAGE = 4.2, MEDICAL = 2.0, HUNTING = 1.6, CITY = 1.6, LANDMARK = 1.2, INDUSTRIAL = 1.2 },
    },
    {
        key = "militia_cell", fi = "Miliisisolu", size = { 2, 5 },
        archetypes = { "militia", "survivor", "veteran" },
        tactics = "defensive", weight = 7,
        poi_weights = { MILITARY = 3.0, INDUSTRIAL = 2.4, VILLAGE = 2.0, BUNKER = 1.6, ABANDONED_BUNKER = 1.2 },
    },
    {
        key = "elite_unit", fi = "Eliittiyksikkö", size = { 3, 5 },
        archetypes = { "elite", "ex_military" },
        tactics = "elite", weight = 3,
        poi_weights = { MILITARY = 5.0, RESEARCH = 3.5, BUNKER = 3.0, ABANDONED_BUNKER = 2.4 },
    },
    {
        key = "island_residents", fi = "Saaren asukkaat", size = { 2, 4 },
        archetypes = { "survivor", "scavenger", "hunter", "security" },
        tactics = "territorial", weight = 4, reserved_zone = "Z4", home_bound = true,
        poi_weights = { VILLAGE = 4.0, HUNTING = 2.0, LANDMARK = 1.5, INDUSTRIAL = 1.0 },
    },
}

G.by_key = {}
for _, g in ipairs(G.list) do G.by_key[g.key] = g end
G.count = #G.list

function G.get(key) return G.by_key[key] end

-- Group classes that may be placed anywhere (reserved-zone classes are placed
-- by the population module's zone pass instead).
function G.general()
    local out = {}
    for _, g in ipairs(G.list) do
        if not g.reserved_zone then out[#out + 1] = g end
    end
    return out
end

return G
