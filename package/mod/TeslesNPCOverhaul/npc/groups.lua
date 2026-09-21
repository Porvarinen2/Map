-- The 13 group classes from the NPC guide.
--
-- `poi_weights` are relative selection weights over POI kinds, not
-- percentages. `tactics` is a classification label used by the live map and by
-- combat scoring; it is not a claim of a separate finished algorithm.
local G = {}

G.list = {
    {
        key = "lone_wanderer", fi = "Yksinäinen kulkija", size = { 1, 1 },
        archetypes = { "survivor", "hunter", "scavenger", "veteran" },
        tactics = "solo", weight = 12,
        poi_weights = { VILLAGE = 3.0, TOWN = 2.0, HUNTING = 2.4, WILDERNESS = 2.2,
                        SHORE = 1.4, JUNCTION = 1.0, SETTLEMENT = 2.0 },
    },
    {
        key = "pair", fi = "Kaksikko", size = { 2, 2 },
        archetypes = { "survivor", "hunter", "police", "ex_military" },
        tactics = "paired", weight = 12,
        poi_weights = { VILLAGE = 3.0, TOWN = 2.2, HUNTING = 2.2, SETTLEMENT = 2.2,
                        JUNCTION = 1.2, WILDERNESS = 1.4 },
    },
    {
        key = "hunters", fi = "Metsästäjät", size = { 2, 4 },
        archetypes = { "hunter", "survivor" },
        tactics = "patient", weight = 10,
        poi_weights = { HUNTING = 5.0, WILDERNESS = 3.4, VILLAGE = 1.2,
                        SHORE = 1.4, SETTLEMENT = 0.9 },
    },
    {
        key = "scavengers", fi = "Keräilijät", size = { 2, 5 },
        archetypes = { "scavenger", "survivor", "bandit" },
        tactics = "opportunist", weight = 14,
        poi_weights = { VILLAGE = 4.0, TOWN = 3.4, CITY = 2.6, SETTLEMENT = 3.0,
                        BUNKER = 1.6, INDUSTRIAL = 2.0, JUNCTION = 1.2 },
    },
    {
        key = "police_patrol", fi = "Poliisipartio", size = { 2, 4 },
        archetypes = { "police", "security" },
        tactics = "disciplined", weight = 8,
        poi_weights = { TOWN = 3.4, CITY = 3.0, VILLAGE = 2.6, MILITARY = 2.2,
                        JUNCTION = 2.0, SETTLEMENT = 2.4 },
    },
    {
        key = "military_group", fi = "Sotilastaustainen ryhmä", size = { 3, 5 },
        archetypes = { "ex_military", "veteran", "bunker_specialist" },
        tactics = "military", weight = 7,
        poi_weights = { MILITARY = 4.4, BUNKER = 3.0, INDUSTRIAL = 2.0,
                        CITY = 1.4, JUNCTION = 1.4 },
    },
    {
        key = "radiation_group", fi = "Säteilyryhmä", size = { 2, 5 },
        archetypes = { "radiation_specialist" },
        tactics = "hazmat", weight = 3, reserved_zone = "C0",
        poi_weights = { CITY = 3.0, INDUSTRIAL = 3.0, TOWN = 2.0, WILDERNESS = 1.6 },
    },
    {
        key = "bunker_group", fi = "Bunkkeriryhmä", size = { 2, 5 },
        archetypes = { "bunker_specialist", "ex_military", "security" },
        tactics = "close_quarters", weight = 5,
        poi_weights = { BUNKER = 5.0, MILITARY = 2.4, INDUSTRIAL = 2.0 },
    },
    {
        key = "bandit_gang", fi = "Rosvojoukko", size = { 2, 5 },
        archetypes = { "bandit", "scavenger" },
        tactics = "aggressive", weight = 11,
        poi_weights = { VILLAGE = 3.6, TOWN = 3.0, SETTLEMENT = 3.0, MILITARY = 2.0,
                        JUNCTION = 2.2, INDUSTRIAL = 1.8 },
    },
    {
        key = "survivor_group", fi = "Selviytyjäryhmä", size = { 2, 5 },
        archetypes = { "survivor", "civilian", "scavenger", "hunter" },
        tactics = "mixed", weight = 13,
        poi_weights = { VILLAGE = 4.2, SETTLEMENT = 3.4, TOWN = 2.4, SHORE = 1.6,
                        WILDERNESS = 1.6, HUNTING = 1.4 },
    },
    {
        key = "militia_cell", fi = "Miliisisolu", size = { 2, 5 },
        archetypes = { "militia", "survivor", "veteran" },
        tactics = "defensive", weight = 7,
        poi_weights = { BUNKER = 3.0, MILITARY = 3.2, INDUSTRIAL = 2.4, TOWN = 1.8,
                        JUNCTION = 1.8 },
    },
    {
        key = "elite_unit", fi = "Eliittiyksikkö", size = { 3, 5 },
        archetypes = { "elite", "ex_military" },
        tactics = "elite", weight = 3,
        poi_weights = { MILITARY = 4.6, INDUSTRIAL = 2.4, BUNKER = 2.0, CITY = 1.4 },
    },
    {
        key = "island_residents", fi = "Saaren asukkaat", size = { 2, 4 },
        archetypes = { "survivor", "scavenger", "hunter", "security" },
        tactics = "territorial", weight = 4, reserved_zone = "Z4", home_bound = true,
        poi_weights = { VILLAGE = 4.0, SHORE = 3.0, SETTLEMENT = 3.0, HUNTING = 1.8,
                        WILDERNESS = 1.4 },
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
