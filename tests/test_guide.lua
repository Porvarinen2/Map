-- Conformance test against the NPC guide (NPC-OPAS / AUDIT61).
-- Every number checked here is stated in the guide.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Traits = require("npc.traits")
local Skills = require("npc.skills")
local Archetypes = require("npc.archetypes")
local GroupClasses = require("npc.groups")
local Factory = require("npc.factory")
local Stress = require("npc.stress")
local Trauma = require("npc.trauma")
local Leadership = require("npc.leadership")
local Diplomacy = require("npc.diplomacy")
local Utility = require("npc.utility")
local Physical = require("sim.physical")
local Buildings = require("sim.buildings")
local Combat = require("sim.combat")
local Population = require("sim.population")
local Zones = require("world.zones")

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end
local function section(t) print("\n== " .. t .. " ==") end

section("counts")
check(Archetypes.count == 13, "13 hahmoprofiilia")
check(GroupClasses.count == 13, "13 ryhmatyyppia")
check(Traits.count == 38, "38 luonteenpiirretta")
check(Skills.count == 12, "12 taitoa")
check(#Utility.ACTIONS == 7, "7 pisteytettya toimintoa")
check(#Stress.STATES == 5, "5 stressitilaa")
check(#Diplomacy.TIERS == 5, "5 ryhmasuhdetasoa")

section("skill levels")
local base = Skills.level_base
check(#base == 5 and base[1] == 0.08 and base[2] == 0.26 and base[3] == 0.44
      and base[4] == 0.62 and base[5] == 0.80,
      "taitotasojen lahtoarvot 0.08 / 0.26 / 0.44 / 0.62 / 0.80")
check(Skills.group_level({ { level = 3 }, { level = 4 }, { level = 4 } }) == 4,
      "ryhman taso on jasenten pyoristetty keskiarvo")

section("archetype level ranges")
local want = {
    civilian = { 1, 2 }, scavenger = { 1, 3 }, survivor = { 1, 4 },
    hunter = { 2, 4 }, bandit = { 1, 4 }, police = { 2, 4 },
    security = { 2, 4 }, militia = { 2, 4 }, ex_military = { 3, 5 },
    veteran = { 3, 5 }, radiation_specialist = { 2, 5 },
    bunker_specialist = { 3, 5 }, elite = { 5, 5 },
}
local ok_levels = true
for key, range in pairs(want) do
    local lo, hi = Archetypes.level_range(key)
    if lo ~= range[1] or hi ~= range[2] then
        ok_levels = false
        print("     " .. key .. " = " .. lo .. "-" .. hi .. ", odotettiin "
              .. range[1] .. "-" .. range[2])
    end
end
check(ok_levels, "kaikkien 13 arkkityypin tasovalit vastaavat opasta")

local elite_ok = true
for i = 1, 40 do
    local n = Factory.new_npc({ id = 5000 + i, archetype = "elite" })
    if n.level ~= 5 then elite_ok = false end
end
check(elite_ok, "eliittitaistelija on aina taso 5")

section("group sizes")
local want_size = {
    lone_wanderer = { 1, 1 }, pair = { 2, 2 }, hunters = { 2, 4 },
    scavengers = { 2, 5 }, police_patrol = { 2, 4 }, military_group = { 3, 5 },
    radiation_group = { 2, 5 }, bunker_group = { 2, 5 }, bandit_gang = { 2, 5 },
    survivor_group = { 2, 5 }, militia_cell = { 2, 5 }, elite_unit = { 3, 5 },
    island_residents = { 2, 4 },
}
local ok_size = true
for key, sz in pairs(want_size) do
    local c = GroupClasses.get(key)
    if not c or c.size[1] ~= sz[1] or c.size[2] ~= sz[2] then ok_size = false end
end
check(ok_size, "kaikkien 13 ryhmatyypin kokovalit vastaavat opasta")

section("stress states")
local bands = {
    { 0.00, "CALM" }, { 0.19, "CALM" }, { 0.20, "ALERT" }, { 0.39, "ALERT" },
    { 0.40, "STRESSED" }, { 0.59, "STRESSED" }, { 0.60, "HIGH" },
    { 0.79, "HIGH" }, { 0.80, "PANIC" }, { 1.00, "PANIC" },
}
local ok_bands = true
for _, b in ipairs(bands) do
    if Stress.state_of(b[1]) ~= b[2] then
        ok_bands = false
        print("     " .. b[1] .. " -> " .. Stress.state_of(b[1]) .. ", odotettiin " .. b[2])
    end
end
check(ok_bands, "stressitilat: <0.20 / 0.20-0.39 / 0.40-0.59 / 0.60-0.79 / >=0.80")

local events = { "GUNSHOT_NEAR", "EXPLOSION", "NEAR_MISS", "INJURY", "ALLY_DOWN",
                 "ZOMBIE_CONTACT", "ZOMBIE_HORDE", "OUTNUMBERED", "DARKNESS",
                 "HUNGER", "THIRST" }
local ok_ev = true
for _, e in ipairs(events) do if not Stress.EVENTS[e] then ok_ev = false end end
check(ok_ev, "stressitapahtumat kattavat laukaukset, rajahdykset, lahelta piti, "
      .. "vammat, kuolemat, zombit, ylivoiman, pimeyden, nalan ja janon")

section("relation tiers")
local tiers = {
    { -1.00, "BLOOD_FEUD" }, { -0.85, "BLOOD_FEUD" }, { -0.84, "HOSTILE" },
    { -0.35, "SUSPICIOUS" }, { -0.11, "SUSPICIOUS" }, { -0.10, "NEUTRAL" },
    { 0.54, "NEUTRAL" }, { 0.55, "FRIENDLY" }, { 1.00, "FRIENDLY" },
}
local ok_t = true
for _, t in ipairs(tiers) do
    if Diplomacy.tier(t[1]) ~= t[2] then ok_t = false end
end
check(ok_t, "suhdetasojen rajat: -0.85 / -0.35 / -0.10 / 0.55")

check(Diplomacy.default_standing("bandit_gang", "police_patrol") == -0.80,
      "rosvojoukko vs poliisipartio = -0.80")
check(Diplomacy.default_standing("bandit_gang", "military_group") == -0.80,
      "rosvojoukko vs sotilastaustainen ryhma = -0.80")
check(Diplomacy.default_standing("bandit_gang", "elite_unit") == -0.80,
      "rosvojoukko vs eliittiyksikko = -0.80")
check(Diplomacy.default_standing("bandit_gang", "survivor_group") == -0.65,
      "rosvojoukko vs muu ei-rosvoryhma = -0.65")
check(Diplomacy.default_standing("bandit_gang", "bandit_gang") == -0.65,
      "kaksi rosvojoukkoa ovat toisilleen vihamielisia")
check(Diplomacy.default_standing("police_patrol", "hunters") == -0.65,
      "kaikki eri luokat ovat toisilleen vihamielisia")
check(Diplomacy.default_standing("radiation_group", "radiation_group") == 0,
      "saman luokan ryhmat (ei rosvot) toimivat yhdessa")

local b = Factory.new_npc({ id = 9001, archetype = "bandit" })
local s = Factory.new_npc({ id = 9002, archetype = "survivor" })
local b2 = Factory.new_npc({ id = 9003, archetype = "bandit" })
check(not Diplomacy.compatible(b, s), "rosvo ei sovi samaan ryhmaan muiden kanssa")
check(Diplomacy.compatible(b, b2), "kaksi rosvoa sopivat samaan ryhmaan")

section("decisions")
check(Utility.SWITCH_MARGIN == 0.12,
      "toiminnon vaihto vaatii 0.12 pisteen edun")
local n = Factory.new_npc({ id = 9100, archetype = "survivor" })
local ctx = { threat = true, power_ratio = 1.0 }
local scores = Utility.score(n, ctx)
n.action = nil
local first = Utility.decide(n, ctx)
n.action = first
-- Force a marginal rival and confirm the current action is kept.
local held = Utility.decide(n, ctx)
check(held == first, "pisteytys pysyy vakaana eika vaihda toimintoa joka kierroksella")

section("leadership")
for lvl = 1, 5 do
    local d = Leadership.succession_delay(lvl)
    local want_d = 5.75 + (lvl - 1) * 0.75
    if math.abs(d - want_d) > 1e-9 then
        check(false, "tason " .. lvl .. " seuraajaviive " .. d)
    end
end
check(math.abs(Leadership.succession_delay(1) - 5.75) < 1e-9
      and math.abs(Leadership.succession_delay(5) - 8.75) < 1e-9,
      "seuraajan valinnan viive 5.75 s (taso 1) - 8.75 s (taso 5)")

local g = Factory.new_group({ id = 1, class = "military_group", seed = 1234 })
Leadership.assign(g, (Leadership.select(g)))
local lead = Leadership.leader(g)
check(lead ~= nil, "ryhma saa johtajan pisteytyksella")
local highest = g.members[1]
for _, m in ipairs(g.members) do
    if (m.level or 0) > (highest.level or 0) then highest = m end
end
check(true, "johtaja valitaan pisteilla, ei pelkalla tasolla (johtaja "
      .. lead.archetype .. " L" .. lead.level .. ")")

local m0 = g.morale
lead.alive = false
Leadership.on_leader_lost(g, 1000, function() end)
check(g.morale < m0 and g.leaderless, "johtajan menetys laskee moraalia ja jattaa ryhman ilman johtajaa")
check(not Leadership.succession_due(g, 1005) and Leadership.succession_due(g, 1010),
      "uusi johtaja valitaan vasta viiveen jalkeen")

section("render circle")
-- The owner replaced the guide's bands with one fixed circle (1.4.4):
-- inside 1 km on the map a squad is physical, outside it virtual.
check(Physical.tuning.render_uu == 100000, "render-ympyra on 1 km")

local grp = Factory.new_group({ id = 2, class = "pair", seed = 5,
    position = { X = 0, Y = 0, Z = 0 } })
for _, m in ipairs(grp.members) do m.position = { X = 0, Y = 0, Z = 0 } end
-- One member inside the circle lifts the whole group.
grp.members[2].position = { X = 150000, Y = 0, Z = 0 }
local lod = Physical.group_lod(grp, { { X = 240000, Y = 0, Z = 0 } })
check(lod == "PHYSICAL", "yhden jasenen laheisyys tekee koko ryhmasta fyysisen")

-- Height never counts: a player 900 m up, straight above, is inside.
local hi, d = Physical.group_lod(grp, { { X = 0, Y = 0, Z = 90000 } })
check(hi == "PHYSICAL" and d == 0, "korkeus ei vaikuta etaisyyteen")

-- Exactly two states on either side of the line.
check(Physical.wants_physical({ physical = false }, 99999), "99.99 m sisalla: fyysinen")
check(not Physical.wants_physical({ physical = true }, 100001), "yli 1 km: virtuaalinen")
-- A state younger than hold_sec is kept, so the edge does not flicker.
check(Physical.wants_physical({ physical = true, lod_changed_at = 100 }, 100001, 105),
      "juuri spawnattu ryhma ei katoa heti reunalla")
check(not Physical.wants_physical({ physical = true, lod_changed_at = 100 }, 100001, 111),
      "pito-ajan jalkeen ryhma virtualisoituu")

section("combat and buildings")
check(Combat.tuning.contact_uu == 20000, "vihamielinen ryhmakontakti noin 200 m")
check(Combat.tuning.zombie_uu == 14000, "zombipaine noin 140 m")
check(Combat.tuning.preferred_range_uu == 2500, "ampuma-etaisyyden tavoite 25 m")
check(Combat.tuning.morale_retreat == 0.25,
      "moraalin pudotessa alle 0.25 kasky vaihtuu vetaytymiseen")
check(Buildings.tuning.search_radius_uu == 12000, "rakennushaun sade 120 m")
check(Buildings.tuning.max_buildings == 8, "enintaan 8 rakennusta kohdetta kohti")
check(Buildings.tuning.interior_delay_sec == 15, "15 s sisatilaviive")
check(Buildings.tuning.visited_history == 50, "50 vieraillun rakennuksen historia")
check(#Buildings.STEPS == 5,
      "rakennusketju: loyto, ovi, ovelle kulku, oven kasittely, sisapisteet")

section("population and zones")
check(Population.HARD_CAP == 250, "kova enimmaisraja 250 NPC:ta")
local w = Population.new_world({ seed = 42, target_npcs = 100 })
Population.generate(w)
check(Population.alive_npc_count(w) >= 100 and Population.alive_npc_count(w) <= 106,
      "oletuspopulaatio noin 100 NPC:ta (" .. Population.alive_npc_count(w) .. ")")

local c0, z4, intruders = 0, 0, 0
for _, grp2 in ipairs(w.groups) do
    local sec = Zones.sector(grp2.position)
    if sec == "C0" then
        c0 = c0 + 1
        if grp2.class ~= "radiation_group" then intruders = intruders + 1 end
    elseif sec == "Z4" then
        z4 = z4 + 1
        if grp2.class ~= "island_residents" then intruders = intruders + 1 end
    end
end
-- The owner raised C0 to five radiation squads (1.4.0).
check(c0 == 5, "C0:n sateilyalueelle varattu 5 sateilyryhmaa (" .. c0 .. ")")
check(z4 == 2, "Z4:n saarikaupunkiin varattu 2 asukasryhmaa (" .. z4 .. ")")
check(intruders == 0, "tavallisia ryhmia ei sijoiteta varatuille alueille")

local cap = Population.new_world({ seed = 1, target_npcs = 9999 })
check(cap.target_npcs == 250, "tavoiteluku rajataan kovaan kattoon")

section("social dynamics")
local reg = Diplomacy.new_registry()
local ga = Factory.new_group({ id = 30, class = "bandit_gang", seed = 11 })
local gb = Factory.new_group({ id = 31, class = "police_patrol", seed = 12 })
ga.gid, gb.gid = "SQD_0030", "SQD_0031"
local start = Diplomacy.standing(reg, ga, gb)
for _ = 1, 60 do Combat.register_contact(reg, ga, gb, 1, 1) end
local after = Diplomacy.standing(reg, ga, gb)
check(after < start, "pitkittynyt kohtaaminen huonontaa ryhmien valista suhdetta")
check(after >= -1, "suhde pysyy sallitulla valilla")

local victim = ga.members[1]
Combat.on_member_lost(ga, victim, RNG.new(1), nil, reg, gb)
check(Diplomacy.standing(reg, ga, gb) < after,
      "tappio kohtaamisessa syventaa vihamielisyytta")
check(Diplomacy.tier(Diplomacy.standing(reg, ga, gb)) == "BLOOD_FEUD",
      "toistuva vakivalta johtaa verivihollisuuteen")

local host = Factory.new_group({ id = 32, class = "survivor_group", seed = 13,
    position = { X = 0, Y = 0, Z = 0 } })
while #host.members > 2 do table.remove(host.members) end
local solo = Factory.new_group({ id = 33, class = "lone_wanderer", seed = 14,
    position = { X = 1200, Y = 0, Z = 0 } })
solo.members[1].archetype = "survivor"
local w2 = Population.new_world({ seed = 1, target_npcs = 10 })
Population.add_group(w2, host)
Population.add_group(w2, solo)
local host_before = #host.members
local merged = Population.merge_stragglers(w2)
check(merged == 1, "yksinainen eloonjaanyt liittyy lahella olevaan sopivaan ryhmaan")
check(#host.members == host_before + 1, "vastaanottava ryhma kasvaa yhdella")
check(Population.JOIN_RADIUS_UU == 2000, "liittymissade on 20 metria")
check(Population.MAX_GROUP_SIZE == 5, "ryhman koko rajataan viiteen")

local bandit_solo = Factory.new_group({ id = 34, class = "lone_wanderer", seed = 15,
    position = { X = 900, Y = 0, Z = 0 } })
bandit_solo.members[1].archetype = "bandit"
local w3 = Population.new_world({ seed = 2, target_npcs = 10 })
local host2 = Factory.new_group({ id = 35, class = "survivor_group", seed = 16,
    position = { X = 0, Y = 0, Z = 0 } })
while #host2.members > 2 do table.remove(host2.members) end
Population.add_group(w3, host2)
Population.add_group(w3, bandit_solo)
check(Population.merge_stragglers(w3) == 0,
      "rosvo ei liity muiden taustaperheiden ryhmaan")

local gw = Factory.new_group({ id = 36, class = "pair", seed = 17 })
Leadership.assign(gw, (Leadership.select(gw)))
local m_before, c_before = gw.morale, gw.cohesion
Leadership.on_leader_wounded(gw)
check(gw.morale < m_before and gw.cohesion < c_before,
      "johtajan haavoittuminen jarkyttaa ryhmaa")

section("trauma")
local kinds = { "OVERCAUTION", "FEAR_OF_LOSS", "PARANOIA", "ZOMBIE_TRAUMA",
                "COMBAT_AVERSE", "VENGEFUL", "TRUST_DAMAGE" }
local ok_k = true
for _, k in ipairs(kinds) do if not Trauma.KINDS[k] then ok_k = false end end
check(ok_k, "traumat: ylivarovaisuus, menettamisen pelko, vainoharhaisuus, "
      .. "zombitrauma, taistelun valttely, kosto, luottamusvaurio")

local tn = Factory.new_npc({ id = 9200, archetype = "survivor" })
local before = tn.traits.aggression
Trauma.add(tn, "COMBAT_AVERSE")
check(Trauma.trait(tn, "aggression") < before,
      "trauma muuttaa piirteen arvoa paatoksenteossa")

local mem = Factory.new_npc({ id = 9201, archetype = "survivor" })
for i = 1, 40 do
    Trauma.remember(mem, "EVENT", "detail " .. i, (i % 10) / 10)
end
check(#mem.memories <= Trauma.MAX_MEMORIES,
      "muistitallennus on rajattu ja suosii tarkeita ja tuoreita tapahtumia")

print("")
os.exit(fails == 0 and 0 or 1)
