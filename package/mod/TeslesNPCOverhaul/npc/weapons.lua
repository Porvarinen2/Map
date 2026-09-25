-- NPC weapons: every spawnable SCUM weapon (no DLC, no explosives or
-- launchers), each with a tier (1 weakest - 5 best) and a kind. A squad class
-- carries the kinds that fit it (hunters bows and hunting rifles, police
-- pistols and SMGs, soldiers assault rifles...), and an NPC the ones of the
-- tier of its skill level (sometimes one lower), so weak NPCs carry
-- improvised melee weapons and the elite the best rifles.
-- Spawn names from the SCUM item list (ribbongaming.com/scum-wiki/items).
--
-- varusteet.lua can override per squad class (or KAIKKI for all):
--   Weapons   - own list, one picked at random (replaces the tiers)
--   Lipas     - false = no magazine in the weapon
--   Tahtaimet - own scope list; TahtainOsuus - share of scoped rifles (0..1)
local W = {}

-- Every weapon: spawn name, tier (1 weakest - 5 best) and kind.
W.LIST = {
    -- improvised melee
    { "1H_ImprovisedKnife", 1, "impro" }, { "1H_Improvised_Glass_Shiv", 1, "impro" },
    { "1H_Improvised_Hammer", 1, "impro" }, { "1H_Improvised_Tomahawk", 1, "impro" },
    { "1H_Improvised_metal_knife", 1, "impro" }, { "1H_Wooden_club", 1, "impro" },
    { "1H_Wooden_club_with_spikes", 1, "impro" }, { "1H_Wooden_club_with_wire", 1, "impro" },
    { "1H_Stone_Axe", 1, "impro" }, { "2H_Stone_Axe", 1, "impro" }, { "2H_Wooden_Sword", 1, "impro" },
    { "2H_Improvised_Gardening_Hoe", 1, "impro" }, { "2H_Improvised_shovel", 1, "impro" },
    { "1H_Metal_Pipe", 1, "impro" }, { "1H_Brass_knuckles", 1, "impro" }, { "Crutch", 1, "impro" },
    { "Razor_Blade", 1, "impro" }, { "2H_Pitchfork", 1, "impro" }, { "2H_Pitchfork_Bent", 1, "impro" },
    -- spears
    { "Improvised_Wooden_Spear", 1, "spear" }, { "Improvised_Stone_Spear", 1, "spear" },
    { "Bone_Spear", 1, "spear" }, { "Improvised_Metal_Spear", 2, "spear" },
    -- tools
    { "1H_Scalpel", 1, "tool" }, { "1H_Crowbar", 2, "tool" }, { "1H_Pipe_Wrench", 2, "tool" },
    { "1H_Little_Spade", 2, "tool" }, { "2H_Shovel_01", 2, "tool" }, { "2H_Shovel_02", 2, "tool" },
    { "2H_Improvised_metal_shovel", 2, "tool" }, { "2H_Pickaxe", 2, "tool" },
    { "2H_Industrial_Gardening_Hoe", 2, "tool" }, { "Sledgehammer", 2, "tool" }, { "Chainsaw", 3, "tool" },
    -- knives and swords
    { "1H_Cleaver", 2, "blade" }, { "1H_SkinningKnife", 2, "hunt_blade" },
    { "1H_Skinning_Knife_02", 2, "hunt_blade" }, { "1H_Hunters_Skinning_Knife_01", 2, "hunt_blade" },
    { "1H_Hunter", 2, "hunt_blade" }, { "1H_Metal_Sword", 2, "blade" }, { "1H_Medieval_Sword", 2, "blade" },
    { "2H_Katana", 3, "blade" }, { "2H_Tang_Dao", 3, "blade" },
    -- axes and bats
    { "1H_Hatchet", 2, "axe" }, { "1H_Small_Axe", 2, "axe" }, { "2H_Axe", 2, "axe" },
    { "Blacksmith_Axe", 2, "axe" }, { "2H_Metal_Axe", 3, "axe" },
    { "2H_Baseball_Bat", 2, "bat" }, { "2H_Baseball_Bat_with_spikes", 2, "bat" },
    { "2H_Baseball_Bat_with_wire", 2, "bat" }, { "2H_Metal_Baseball_Bat", 2, "bat" },
    { "1H_Police_Baton", 2, "baton" },
    { "1H_Military_Survival_Knife", 3, "mil_melee" }, { "1H_Military_Tomahawk", 3, "mil_melee" },
    { "1H_Military_Shovel", 3, "mil_melee" },
    -- bows and crossbows
    { "Improvised_Bow", 1, "bow_crude" }, { "Improvised_Bow_25", 1, "bow_crude" },
    { "Improvised_Bow_30", 1, "bow_crude" }, { "Improvised_Bow_35", 2, "bow_crude" },
    { "Recurve_Bow", 2, "bow" }, { "Recurve_Bow_50", 2, "bow" }, { "Penobscot_Bow_40", 2, "bow" },
    { "Recurve_Bow_60", 3, "bow" }, { "Recurve_Bow_70", 3, "bow" }, { "Manchu_Bow_50", 3, "bow" },
    { "Snake_Skin_Bow", 3, "bow" }, { "Takedown_Bow", 3, "bow" }, { "Recurve_Bow_80", 4, "bow" },
    { "Recurve_Bow_90", 4, "bow" }, { "Recurve_Bow_100", 4, "bow" }, { "Recurve_Bow_Hunter", 4, "bow" },
    { "Compound_Bow", 4, "compound" },
    { "Weapon_Improvised_Crossbow", 2, "xbow_impro" }, { "Weapon_BlackHawk_Crossbow", 4, "xbow" },
    -- firearms
    { "Weapon_Improvised_Handgun", 2, "gun_impro" }, { "Weapon_Improvised_Rifle", 2, "gun_impro" },
    { "Weapon_M1911", 3, "pistol" }, { "Weapon_M9", 3, "pistol" }, { "Weapon_HS9", 3, "pistol" },
    { "Weapon_Block21", 3, "pistol" }, { "Weapon_SF19", 3, "pistol" }, { "Weapon_Krueger", 3, "pistol" },
    { "Weapon_DEagle_50", 4, "pistol" },
    { "Weapon_Judge44", 3, "revolver" }, { "Weapon_PeaceKeeper38", 3, "revolver" },
    { "Weapon_Serpent357", 3, "revolver" }, { "Weapon_Viper_M357", 3, "revolver" },
    { "Weapon_Deagle_357", 4, "revolver" },
    { "Weapon_M1887_Sawed_off", 3, "sawed" }, { "Weapon_DT11B_Sawed_Off", 3, "sawed" },
    { "Weapon_M1887", 3, "shotgun" }, { "Weapon_DT11B", 3, "shotgun" }, { "Weapon_SDASS", 3, "shotgun" },
    { "Weapon_590A11", 3, "shotgun" }, { "Weapon_Trench_Gun", 3, "shotgun" },
    { "Weapon_98k_Karabiner", 3, "bolt" }, { "Weapon_MosinNagant", 3, "bolt" },
    { "Weapon_Hunter85_V2", 3, "bolt" }, { "Weapon_CarbonHunter", 4, "bolt" },
    { "Weapon_SKS", 4, "semi" }, { "Weapon_M1_Garand", 4, "semi" },
    { "Weapon_MAC10", 4, "smg" }, { "Weapon_TommyGun", 4, "smg" }, { "Weapon_UMP45", 4, "smg" },
    { "Weapon_MP5", 4, "smg" }, { "Weapon_MP5_K", 4, "smg" }, { "Weapon_MP5_SD", 5, "smg" },
    { "Weapon_AKS_74U", 4, "ak" }, { "Weapon_AKM", 4, "ak" }, { "Weapon_AK47", 4, "ak" },
    { "Weapon_AK15", 5, "ak" }, { "Weapon_VHS2", 4, "assault" }, { "Weapon_M16A4", 4, "assault" },
    { "Weapon_MK18", 5, "assault" }, { "Weapon_SCAR_L", 5, "assault" }, { "Weapon_VHS2_Rail", 5, "assault" },
    { "Weapon_SCAR_DMR", 5, "dmr" }, { "Weapon_AS_Val", 5, "dmr" }, { "Weapon_VSS_VZ", 5, "dmr" },
    { "Weapon_SVD_Dragunov", 5, "dmr" },
    { "Weapon_M82A1_Black", 5, "sniper" }, { "Weapon_AWM", 5, "sniper" }, { "Weapon_AWP", 5, "sniper" },
    { "Weapon_RPK", 5, "lmg" }, { "Weapon_M249", 5, "lmg" },
}

local CIVIL = { "impro", "spear", "tool", "blade", "hunt_blade", "axe", "bat", "bow_crude", "bow",
                "xbow_impro", "gun_impro", "pistol", "revolver", "sawed", "shotgun", "bolt" }
local function with(base, more)
    local t = {}
    for _, k in ipairs(base) do t[#t + 1] = k end
    for _, k in ipairs(more or {}) do t[#t + 1] = k end
    return t
end

-- What each squad class carries: the kinds of weapon that fit it, a few
-- single weapons on top (names), and its tier floor and ceiling.
W.CLASS = {
    lone_wanderer   = { kinds = CIVIL, max = 4 },
    pair            = { kinds = with(CIVIL, { "compound", "semi" }), names = { "Weapon_AK47", "Weapon_AKM" }, max = 4 },
    survivor_group  = { kinds = with(CIVIL, { "compound", "semi" }), names = { "Weapon_AK47", "Weapon_AKM" }, max = 4 },
    island_residents = { kinds = CIVIL, max = 4 },
    scavengers      = { kinds = { "impro", "spear", "tool", "bat", "blade", "bow_crude", "xbow_impro", "gun_impro",
                                  "pistol", "revolver", "sawed" }, max = 3 },
    hunters         = { kinds = { "hunt_blade", "axe", "spear", "bow_crude", "bow", "compound", "xbow_impro", "xbow",
                                  "bolt", "semi" }, names = { "Weapon_M1887", "Weapon_DT11B", "Weapon_Deagle_357",
                                  "Weapon_Viper_M357" },
                        min = 2, TahtainOsuus = 0.4 },
    police_patrol   = { names = { "1H_Police_Baton", "Weapon_M1911", "Weapon_M9", "Weapon_HS9", "Weapon_Block21",
                                  "Weapon_SF19", "Weapon_590A11", "Weapon_SDASS", "Weapon_MP5", "Weapon_MP5_K",
                                  "Weapon_UMP45", "Weapon_M16A4", "Weapon_MP5_SD" }, min = 2 },
    bandit_gang     = { kinds = { "impro", "bat", "axe", "blade", "tool", "gun_impro", "pistol", "revolver", "sawed",
                                  "shotgun", "ak" }, names = { "Weapon_MAC10", "Weapon_TommyGun" }, max = 4 },
    militia_cell    = { kinds = { "mil_melee", "axe", "pistol", "revolver", "shotgun", "bolt", "semi", "ak" },
                        names = { "Weapon_RPK", "Weapon_SVD_Dragunov" }, min = 3, TahtainOsuus = 0.2 },
    radiation_group = { kinds = { "mil_melee", "pistol", "shotgun", "smg", "ak", "assault", "dmr" }, min = 3 },
    bunker_group    = { kinds = { "mil_melee", "pistol", "shotgun", "smg", "ak", "assault", "dmr", "lmg" }, min = 3 },
    military_group  = { kinds = { "mil_melee", "pistol", "smg", "ak", "assault", "dmr", "sniper", "lmg" },
                        min = 4, TahtainOsuus = 0.35 },
    elite_unit      = { kinds = { "smg", "ak", "assault", "dmr", "sniper", "lmg" }, min = 5, TahtainOsuus = 0.5 },
}
W.DEFAULT_SCOPE_SHARE = 0.1

-- Tier lists over every weapon (for squads with no theme, e.g. ryhmat.lua's).
W.TIERS = { {}, {}, {}, {}, {} }
for _, e in ipairs(W.LIST) do table.insert(W.TIERS[e[2]], e[1]) end

-- The weapons a squad class carries at each tier.
local pools = {}
function W.pool(class, tier)
    local c = W.CLASS[class]
    if not c then return W.TIERS[tier] end
    pools[class] = pools[class] or {}
    if not pools[class][tier] then
        local kinds, names, out = {}, {}, {}
        for _, k in ipairs(c.kinds or {}) do kinds[k] = true end
        for _, n in ipairs(c.names or {}) do names[n] = true end
        for _, e in ipairs(W.LIST) do
            if e[2] == tier and (kinds[e[3]] or names[e[1]]) then out[#out + 1] = e[1] end
        end
        pools[class][tier] = out
    end
    return pools[class][tier]
end

-- The magazine each weapon takes (weapons with a built-in magazine - revolvers,
-- shotguns, bolt-action rifles, bows - are not listed).
W.MAGAZINE = {
    weapon_ak15 = "Magazine_AK15", weapon_ak47 = "Magazine_AK47", weapon_akm = "Magazine_AK47",
    weapon_aks_74u = "Magazine_AKS_74U", weapon_as_val = "Magazine_AS_Val", weapon_vss_vz = "Magazine_AS_Val",
    weapon_awm = "Magazine_AWM", weapon_awp = "Magazine_AWP", weapon_block21 = "Magazine_Block21",
    weapon_carbonhunter = "Magazine_CarbonHunter", weapon_sks = "Magazine_Clip_SKS",
    weapon_deagle_357 = "Magazine_DEagle_357", weapon_deagle_50 = "Magazine_DEagle_50",
    weapon_hs9 = "Magazine_HS9", weapon_hunter85_v2 = "Magazine_Hunter85_V2", weapon_krueger = "Magazine_Krueger",
    weapon_m16a4 = "Magazine_M16", weapon_mk18 = "Magazine_M16", weapon_scar_l = "Magazine_M16",
    weapon_m1911 = "Magazine_M1911", weapon_m249 = "Magazine_M249", weapon_m82a1_black = "Magazine_M82A1",
    weapon_m9 = "Magazine_M9", weapon_mac10 = "Magazine_MAC10", weapon_mp5 = "Magazine_MP5",
    weapon_mp5_k = "Magazine_MP5", weapon_mp5_sd = "Magazine_MP5", weapon_rpk = "Magazine_RPK",
    weapon_scar_dmr = "Magazine_SCAR_DMR", weapon_sf19 = "Magazine_SF19",
    weapon_svd_dragunov = "Magazine_SVD_Dragunov", weapon_tommygun = "Magazine_TommyGun",
    weapon_ump45 = "Magazine_UMP45", weapon_vhs2 = "Magazine_VHS2", weapon_vhs2_rail = "Magazine_VHS2",
}

-- Scopes that fit each scoped rifle (bolt-action, marksman, sniper).
W.SCOPES = {
    weapon_hunter85_v2 = { "WeaponScope_HuntingScope" }, weapon_carbonhunter = { "WeaponScope_HuntingScope" },
    weapon_98k_karabiner = { "WeaponScope_ZF39" }, weapon_mosinnagant = { "WeaponScope_PU" },
    weapon_svd_dragunov = { "WeaponScope_Dragunov", "WeaponScope_POSP" }, weapon_vss_vz = { "WeaponScope_POSP" },
    weapon_m82a1_black = { "WeaponScope_M82A1" }, weapon_awm = { "WeaponScope_HuntingScope" },
    weapon_awp = { "WeaponScope_HuntingScope" }, weapon_scar_dmr = { "WeaponScope_ACOG_01" },
    weapon_m1_garand = { "WeaponScope_HuntingScope" },
}

function W.magazine_for(weapon)
    return W.MAGAZINE[tostring(weapon):lower()]
end
function W.scopes_for(weapon)
    return W.SCOPES[tostring(weapon):lower()] or {}
end

local function nonempty(t) return type(t) == "table" and #t > 0 end

-- The tier of an NPC: its skill level, one lower now and then, within its
-- squad class's floor and ceiling.
function W.tier(class, level, roll)
    local t = math.max(1, math.min(5, math.floor(tonumber(level) or 1)))
    if (roll or math.random()) < 0.25 then t = t - 1 end
    local c = W.CLASS[class] or {}
    return math.max(c.min or 1, math.min(c.max or 5, t))
end

-- The weapons of a class at a tier, or at the nearest tier that has any.
function W.pool_near(class, tier)
    for d = 0, 4 do
        for _, t in ipairs({ tier - d, tier + d }) do
            if t >= 1 and t <= 5 then
                local p = W.pool(class, t)
                if #p > 0 then return p, t end
            end
        end
    end
    return {}, tier
end

-- The weapon setup of one NPC: varusteet.lua's own class entry wins, then
-- KAIKKI, then the class's weapons at the NPC's tier.
function W.for_member(class, level, gear, roll)
    gear = gear or {}
    local own, all, cls = gear[class] or {}, gear.KAIKKI or gear.ALL or {}, W.CLASS[class] or {}
    local function pick(key)
        for _, src in ipairs({ own, all, cls }) do
            local v = src[key]
            if key == "Weapons" or key == "Tahtaimet" then
                if nonempty(v) and src ~= cls then return v end
            elseif v ~= nil then
                return v
            end
        end
        return nil
    end
    return {
        Weapons = pick("Weapons") or (W.pool_near(class, W.tier(class, level, roll))),
        Lipas = pick("Lipas"),
        Tahtaimet = pick("Tahtaimet"),
        TahtainOsuus = tonumber(pick("TahtainOsuus")) or W.DEFAULT_SCOPE_SHARE,
    }
end

-- Weapon condition by squad class: the elite look after their weapons,
-- scavengers and bandits hardly at all. { lowest, highest } share of the
-- weapon's full condition.
W.CONDITION = {
    elite_unit = { 0.85, 1.0 }, military_group = { 0.7, 0.95 }, police_patrol = { 0.7, 0.95 },
    bunker_group = { 0.6, 0.9 }, radiation_group = { 0.6, 0.9 }, hunters = { 0.55, 0.9 },
    militia_cell = { 0.45, 0.8 }, survivor_group = { 0.4, 0.8 }, pair = { 0.4, 0.8 },
    island_residents = { 0.4, 0.75 }, lone_wanderer = { 0.35, 0.75 },
    bandit_gang = { 0.2, 0.55 }, scavengers = { 0.15, 0.5 },
}
W.DEFAULT_CONDITION = { 0.35, 0.75 }

local KIND = {}
for _, e in ipairs(W.LIST) do KIND[e[1]:lower()] = e[3] end
function W.kind(name) return KIND[tostring(name):lower()] end

-- How far and how well a weapon shoots in the squads' own fights.
-- range in UU (100 = 1 m); acc multiplies the hit chance.
W.PROFILE = {
    melee = { range = 300, acc = 1.2 },
    bow_crude = { range = 3000, acc = 0.6 }, bow = { range = 5000, acc = 0.8 },
    compound = { range = 6000, acc = 0.95 }, xbow_impro = { range = 4000, acc = 0.7 },
    xbow = { range = 6000, acc = 1.0 }, gun_impro = { range = 3000, acc = 0.55 },
    pistol = { range = 5000, acc = 0.85 }, revolver = { range = 5000, acc = 0.9 },
    sawed = { range = 1500, acc = 1.1 }, shotgun = { range = 3500, acc = 1.0 },
    smg = { range = 8000, acc = 0.9 }, bolt = { range = 15000, acc = 1.1 },
    semi = { range = 15000, acc = 1.0 }, ak = { range = 15000, acc = 0.9 },
    assault = { range = 15000, acc = 1.0 }, dmr = { range = 15000, acc = 1.15 },
    sniper = { range = 15000, acc = 1.2 }, lmg = { range = 15000, acc = 0.85 },
}
local MELEE = { impro = true, spear = true, tool = true, blade = true, hunt_blade = true, axe = true,
                bat = true, baton = true, mil_melee = true }
-- A scope: 200 m and a far steadier aim.
W.SCOPE_RANGE = 20000
W.SCOPE_ACC = 1.8
function W.profile(name, scoped)
    local k = W.kind(name)
    local p = (k and MELEE[k]) and W.PROFILE.melee or (k and W.PROFILE[k]) or { range = 15000, acc = 1.0 }
    if scoped and not MELEE[k or ""] then
        return { range = math.max(p.range, W.SCOPE_RANGE), acc = p.acc * W.SCOPE_ACC, scoped = true }
    end
    return p
end

-- Weapons that fire alike. A ghost weapon (the NPC fires SCUM's hidden
-- weapon, a squad weapon is shown in its hand) must look like what it
-- shoots: no SVD in hand firing buckshot.
local GROUP = {
    shotgun = "shotgun", sawed = "shotgun",
    bolt = "bolt", semi = "semi", dmr = "semi", sniper = "semi",
    ak = "auto", assault = "auto", lmg = "auto",
    smg = "smg",
    pistol = "pistol", revolver = "pistol",
    gun_impro = "improvised",
    bow_crude = "bow", bow = "bow", compound = "bow",
    xbow_impro = "crossbow", xbow = "crossbow",
}
-- Sniper rifles that are bolt-action: they only stand in for bolt-actions
-- (an AWP must not fire as fast as a Garand).
W.BOLT_SNIPERS = { weapon_awm = true, weapon_awp = true }
function W.group(name)
    local k = W.kind(name)
    if not k then return nil end
    if W.BOLT_SNIPERS[name:lower()] then return "bolt" end
    return GROUP[k] or "melee"
end
-- Weapons with a silencer built in: they sound like a bow, so they are only
-- paired with each other (an AS Val may show as a VSS, never as a SCAR).
W.SUPPRESSED = { weapon_as_val = true, weapon_vss_vz = true, weapon_mp5_sd = true }
local function quiet(n) return W.SUPPRESSED[n:lower()] == true end
local function tier_of(n)
    for _, e in ipairs(W.LIST) do if e[1]:lower() == n:lower() then return e[2] end end
    return nil
end
-- Shown weapons for an NPC whose real weapon is `own`, closest first: the
-- same kind (member's list, then its squad class's weapons, nearest tier
-- first), then the same group within one tier. Never another group, never
-- a silenced one for a loud one or the other way round.
function W.similar(own, class, first)
    local k, g, t = W.kind(own), W.group(own), tier_of(own)
    if not k then return {} end
    local q = quiet(own)
    local pool = {}
    for _, n in ipairs(first or {}) do pool[#pool + 1] = n end
    for tt = 1, 5 do for _, n in ipairs(W.pool(class, tt)) do pool[#pool + 1] = n end end
    local out, seen = {}, {}
    local function pass(same_kind)
        local found = {}
        for i, n in ipairs(pool) do
            local l = n:lower()
            local nk = W.kind(n)
            if not seen[l] and nk and quiet(n) == q and W.group(n) == g and (nk == k or not same_kind) then
                local d = math.abs((tier_of(n) or t or 3) - (t or 3))
                if same_kind or d <= 1 then
                    seen[l] = true
                    found[#found + 1] = { n = n, d = d, i = i }
                end
            end
        end
        table.sort(found, function(x, y)
            local fx, fy = x.i <= #(first or {}), y.i <= #(first or {})
            if fx ~= fy then return fx end
            if x.d ~= y.d then return x.d < y.d end
            return x.i < y.i
        end)
        for _, f in ipairs(found) do out[#out + 1] = f.n end
    end
    pass(true)
    pass(false)
    return out
end

-- The weapon one NPC carries, picked once and kept (saved with the NPC):
-- { weapon, scoped, condition }.
function W.gear_for(class, m, gear, rng)
    local setup = W.for_member(class, m.level, gear, rng:float())
    local list = setup.Weapons or {}
    if #list == 0 then return nil, setup end
    local name = list[rng:int(1, #list)]
    local scoped = #W.scopes_for(name) > 0 and rng:float() < (setup.TahtainOsuus or 0)
    local c = W.CONDITION[class] or W.DEFAULT_CONDITION
    return { weapon = name, scoped = scoped, condition = c[1] + (c[2] - c[1]) * rng:float() }, setup
end

return W
