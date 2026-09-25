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
        levels = { 4, 5 },
        tactics = "defensive", weight = 7,
        poi_weights = { MILITARY = 3.0, INDUSTRIAL = 2.4, VILLAGE = 2.0, BUNKER = 1.6, ABANDONED_BUNKER = 1.2 },
    },
    {
        key = "elite_unit", fi = "Eliittiyksikkö", size = { 3, 5 },
        archetypes = { "elite", "ex_military" },
        -- The hardest squad: every member a level 5 Guard, about half of
        -- them in the Abandoned Bunker body.
        level = 5, bunker_share = 0.5,
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

-- A class that sets its members' level (level = 5, or levels = { 4, 5 }):
-- the level of the member with this seed, the same every time; nil when the
-- class leaves it to the archetype.
function G.member_level(cls, seed)
    if not cls then return nil end
    if cls.level then return cls.level end
    if cls.levels then
        local lo, hi = cls.levels[1], cls.levels[2]
        return lo + (math.floor((tonumber(seed) or 0) / 7) % (hi - lo + 1))
    end
    return nil
end

-- --------------------------------------------------------- own classes ---

-- Squad classes the owner adds in ryhmat.lua (kept across updates). Finnish
-- keys, checked and filled with sensible defaults; every problem is reported
-- back as a line for boot.log instead of stopping the mod.
local POI_KINDS = { CITY = true, VILLAGE = true, HUNTING = true, MILITARY = true,
    BUNKER = true, ABANDONED_BUNKER = true, RESEARCH = true, INDUSTRIAL = true,
    MEDICAL = true, LANDMARK = true }

function G.register_custom(defs)
    local notes = {}
    local Archetypes = require("npc.archetypes")
    for i, d in ipairs(defs or {}) do
        local key = d.key or d.avain
        if type(key) ~= "string" or not key:match("^[a-z][a-z0-9_]*$") then
            notes[#notes + 1] = "ryhmat.lua #" .. i .. ": avain puuttuu tai on virheellinen (pienet kirjaimet ja _)"
        elseif G.by_key[key] and not G.by_key[key].custom then
            notes[#notes + 1] = "ryhmat.lua: " .. key .. " on jo modin oma luokka - valitse toinen avain"
        else
            local size = d.koko or d.size or { 2, 4 }
            local lo = math.max(1, math.min(5, math.floor(tonumber(size[1]) or 2)))
            local hi = math.max(lo, math.min(5, math.floor(tonumber(size[2] or size[1]) or lo)))
            local arche = {}
            for _, a in ipairs(d.tausta or d.archetypes or { "survivor" }) do
                if Archetypes.get(a) then arche[#arche + 1] = a
                else notes[#notes + 1] = "ryhmat.lua: " .. key .. ": tuntematon tausta " .. tostring(a) end
            end
            if #arche == 0 then arche = { "survivor" } end
            local weights = {}
            for kind, w in pairs(d.kohteet or d.poi_weights or { VILLAGE = 3, CITY = 2 }) do
                if POI_KINDS[kind] and tonumber(w) and tonumber(w) > 0 then weights[kind] = tonumber(w)
                else notes[#notes + 1] = "ryhmat.lua: " .. key .. ": tuntematon kohde " .. tostring(kind) end
            end
            if next(weights) == nil then weights = { VILLAGE = 3, CITY = 2 } end
            local body, variant = G.parse_body(d.runko or d.body)
            local cls = {
                key = key, fi = d.nimi or d.fi or key, size = { lo, hi },
                archetypes = arche, tactics = d.taktiikka or d.tactics or "mixed",
                weight = tonumber(d.yleisyys or d.weight) or 0,
                poi_weights = weights,
                custom = true,
                guaranteed = math.max(0, math.floor(tonumber(d.maara or d.count) or 1)),
                body = body,
                variant = variant,
                color = d.vari or d.color,
                hostile_to = d.vihamieliset or d.hostile_to or {},
                authority = d.viranomainen == true or d.authority == true,
            }
            if G.by_key[key] then
                for j, c in ipairs(G.list) do if c.key == key then G.list[j] = cls end end
            else
                G.list[#G.list + 1] = cls
            end
            G.by_key[key] = cls
            notes[#notes + 1] = string.format("ryhmat.lua: %s (%s) %d-%d NPC, %d ryhmaa kartalla",
                key, cls.fi, lo, hi, cls.guaranteed)
        end
    end
    G.count = #G.list
    return notes
end

-- A body name from ryhmat.lua / varusteet.lua (Runko): the NPC type SCUM
-- dresses the squad as. SCUM picks the outfit on the player's machine from
-- the NPC type's own list, so the type is what a server can choose.
local BODY_VARIANT = { Radiation = "Radiation", Bunker = "AbandonedBunker", AbandonedBunker = "AbandonedBunker" }
function G.parse_body(name)
    if type(name) ~= "string" then return nil, nil end
    local n = name:sub(1, 1):upper() .. name:sub(2):lower()
    if n == "Abandonedbunker" then n = "AbandonedBunker" end
    if n == "Guard" or n == "Drifter" then return n, nil end
    if BODY_VARIANT[n] then return nil, BODY_VARIANT[n] end
    return nil, nil
end

-- varusteet.lua: Runko per squad class (KAIKKI = every class but the
-- radiation squads, who always wear the hazmat body).
function G.apply_bodies(gear)
    local notes = {}
    if type(gear) ~= "table" then return notes end
    local function set(cls, runko)
        local body, variant = G.parse_body(runko)
        if not (body or variant) then
            notes[#notes + 1] = "varusteet.lua: " .. cls.key .. ": tuntematon Runko " .. tostring(runko)
            return
        end
        cls.body, cls.variant = body, variant
        notes[#notes + 1] = "varusteet.lua: " .. cls.key .. " Runko = " .. tostring(body or variant)
    end
    local all = gear.KAIKKI or gear.ALL
    if type(all) == "table" and all.Runko then
        for _, cls in ipairs(G.list) do
            if cls.key ~= "radiation_group" then set(cls, all.Runko) end
        end
    end
    for key, lo in pairs(gear) do
        if type(lo) == "table" and lo.Runko and G.by_key[key] then
            if key == "radiation_group" then
                notes[#notes + 1] = "varusteet.lua: radiation_group pysyy sateilypuvussa"
            else
                set(G.by_key[key], lo.Runko)
            end
        end
    end
    return notes
end

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
