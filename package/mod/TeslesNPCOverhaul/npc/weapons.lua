-- NPC weapons: every spawnable SCUM weapon (no DLC, no explosives or
-- launchers), in five tiers by how strong it is. An NPC gets a weapon from
-- the tier of its skill level (1-5), sometimes one tier lower, so weak NPCs
-- carry improvised melee weapons and bows and the elite the best rifles.
-- Spawn names from the SCUM item list (ribbongaming.com/scum-wiki/items).
--
-- varusteet.lua can override per squad class (or KAIKKI for all):
--   Weapons   - own list, one picked at random (replaces the tiers)
--   Lipas     - false = no magazine in the weapon
--   Tahtaimet - own scope list; TahtainOsuus - share of scoped rifles (0..1)
local W = {}

W.TIERS = {
    -- 1: improvised melee, spears, crude bows
    {
        "1H_ImprovisedKnife", "1H_Improvised_Glass_Shiv", "1H_Improvised_Hammer",
        "1H_Improvised_Tomahawk", "1H_Improvised_metal_knife", "1H_Wooden_club",
        "1H_Wooden_club_with_spikes", "1H_Wooden_club_with_wire", "1H_Stone_Axe", "2H_Stone_Axe",
        "2H_Improvised_Gardening_Hoe", "2H_Improvised_shovel", "2H_Wooden_Sword", "1H_Metal_Pipe",
        "1H_Brass_knuckles", "2H_Pitchfork", "2H_Pitchfork_Bent",
        "Improvised_Wooden_Spear", "Improvised_Stone_Spear", "Bone_Spear",
        "Improvised_Bow", "Improvised_Bow_25", "Improvised_Bow_30",
    },
    -- 2: real melee weapons, improvised firearms, simple bows
    {
        "1H_Cleaver", "1H_Crowbar", "1H_Hatchet", "1H_Small_Axe", "1H_Pipe_Wrench", "1H_Little_Spade",
        "1H_SkinningKnife", "1H_Skinning_Knife_02", "1H_Hunters_Skinning_Knife_01", "1H_Metal_Sword",
        "1H_Medieval_Sword", "2H_Axe", "2H_Baseball_Bat", "2H_Baseball_Bat_with_spikes",
        "2H_Baseball_Bat_with_wire", "2H_Metal_Baseball_Bat", "2H_Improvised_metal_shovel",
        "2H_Shovel_01", "2H_Shovel_02", "2H_Pickaxe", "2H_Industrial_Gardening_Hoe",
        "Improvised_Metal_Spear", "Improvised_Bow_35", "Recurve_Bow", "Recurve_Bow_50",
        "Weapon_Improvised_Handgun", "Weapon_Improvised_Rifle", "Weapon_Improvised_Crossbow",
    },
    -- 3: handguns, shotguns, old bolt-action rifles, good melee and bows
    {
        "Weapon_M1911", "Weapon_M9", "Weapon_HS9", "Weapon_Block21", "Weapon_Judge44",
        "Weapon_PeaceKeeper38", "Weapon_Serpent357", "Weapon_Viper_M357", "Weapon_SF19",
        "Weapon_Krueger", "Weapon_M1887", "Weapon_M1887_Sawed_off", "Weapon_DT11B",
        "Weapon_DT11B_Sawed_Off", "Weapon_SDASS", "Weapon_590A11", "Weapon_Trench_Gun",
        "Weapon_98k_Karabiner", "Weapon_MosinNagant", "Weapon_SKS", "Weapon_Hunter85_V2",
        "1H_Military_Survival_Knife", "1H_Military_Tomahawk", "1H_Military_Shovel", "2H_Metal_Axe",
        "2H_Katana", "2H_Tang_Dao", "Recurve_Bow_60", "Recurve_Bow_70", "Compound_Bow",
    },
    -- 4: submachine guns, assault rifles, strong handguns
    {
        "Weapon_MP5", "Weapon_MP5_K", "Weapon_MP5_SD", "Weapon_UMP45", "Weapon_MAC10",
        "Weapon_TommyGun", "Weapon_AKS_74U", "Weapon_AKM", "Weapon_AK47", "Weapon_VHS2",
        "Weapon_M1_Garand", "Weapon_DEagle_50", "Weapon_Deagle_357", "Weapon_CarbonHunter",
        "Weapon_M16A4",
    },
    -- 5: the best: modern assault and marksman rifles, snipers, machine guns
    {
        "Weapon_AK15", "Weapon_MK18", "Weapon_SCAR_L", "Weapon_SCAR_DMR", "Weapon_AS_Val",
        "Weapon_VSS_VZ", "Weapon_SVD_Dragunov", "Weapon_RPK", "Weapon_M249", "Weapon_M82A1_Black",
        "Weapon_AWM", "Weapon_AWP", "Weapon_VHS2_Rail",
    },
}

-- Squad classes with a weapon list of their own, and the tier floor/cap of
-- the rest (military never below assault rifles, the elite at the top).
W.CLASS = {
    police_patrol  = { Weapons = { "Weapon_MP5", "Weapon_M1911", "Weapon_Block21" } },
    hunters        = { Weapons = { "Weapon_Hunter85_V2", "Weapon_CarbonHunter" }, TahtainOsuus = 0.4 },
    military_group = { min = 4, TahtainOsuus = 0.35 },
    elite_unit     = { min = 5, TahtainOsuus = 0.5 },
    militia_cell   = { min = 3 },
    bunker_group   = { min = 3 },
    radiation_group = { min = 3 },
}
W.DEFAULT_SCOPE_SHARE = 0.1

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
-- squad class's floor.
function W.tier(class, level, roll)
    local t = math.max(1, math.min(5, math.floor(tonumber(level) or 1)))
    if (roll or math.random()) < 0.25 then t = t - 1 end
    local c = W.CLASS[class] or {}
    return math.max(c.min or 1, math.min(5, t))
end

-- The weapon setup of one NPC: varusteet.lua's own class entry wins, then
-- KAIKKI, then the class list above, then the tier of its level.
function W.for_member(class, level, gear, roll)
    gear = gear or {}
    local own, all, cls = gear[class] or {}, gear.KAIKKI or gear.ALL or {}, W.CLASS[class] or {}
    local function pick(key)
        for _, src in ipairs({ own, all, cls }) do
            local v = src[key]
            if key == "Weapons" or key == "Tahtaimet" then
                if nonempty(v) then return v end
            elseif v ~= nil then
                return v
            end
        end
        return nil
    end
    return {
        Weapons = pick("Weapons") or W.TIERS[W.tier(class, level, roll)],
        Lipas = pick("Lipas"),
        Tahtaimet = pick("Tahtaimet"),
        TahtainOsuus = tonumber(pick("TahtainOsuus")) or W.DEFAULT_SCOPE_SHARE,
    }
end

return W
