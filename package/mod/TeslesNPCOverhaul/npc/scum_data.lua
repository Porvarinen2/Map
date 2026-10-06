-- SCUM's own numbers for its armed NPCs, read from the game files (FModel
-- export of Characters/NPCs/Armed_NPCs and Items/Weapons, UE4SS header dump).
-- The director fights squads against squads with these, so a fight between
-- two squads runs at the rhythm, range and toughness of a fight with SCUM's
-- own NPCs.
local S = {}

-- MaxHealth per NPC level (NPCGuardCommonData_Lvl_1..5 / Drifter alike).
S.MAX_HEALTH = { 160, 180, 200, 220, 240 }
function S.max_health(level)
    local lv = math.max(1, math.min(5, math.floor(tonumber(level) or 3)))
    return S.MAX_HEALTH[lv]
end

-- ArmedNPCDifficultyLevelSettings: how SCUM's NPCs fire, per server NPC
-- difficulty (0 easy, 1 normal, 2 hard). shots = shots in a row, gap = time
-- between them, pause = rest after the row, spread = SCUM's spread
-- multiplier (1 = the weapon's own), draw = a bow's draw and hold.
S.FIRE = {
    [0] = {
        handgun = { shots = 2, gap = { 1.5, 2.0 }, pause = { 3.0, 4.0 }, spread = 3.0 },
        auto = { shots = 6, gap = { 0.1, 0.1 }, pause = { 2.0, 3.0 }, spread = 4.0 },
        manual = { shots = 2, gap = { 1.5, 2.0 }, pause = { 3.0, 4.0 }, spread = 2.0 },
        bow = { shots = 1, gap = { 0, 0 }, pause = { 4.5, 5.0 }, spread = 5.0 },
        xbow = { shots = 1, gap = { 0, 0 }, pause = { 3.5, 5.0 }, spread = 3.0 },
    },
    [1] = {
        handgun = { shots = 3, gap = { 0.75, 1.25 }, pause = { 2.0, 3.0 }, spread = 2.0 },
        auto = { shots = 6, gap = { 0.1, 0.1 }, pause = { 1.5, 2.0 }, spread = 2.0 },
        manual = { shots = 2, gap = { 0.75, 1.25 }, pause = { 2.0, 3.0 }, spread = 1.5 },
        bow = { shots = 1, gap = { 0, 0 }, pause = { 3.0, 3.5 }, spread = 3.0 },
        xbow = { shots = 1, gap = { 0, 0 }, pause = { 2.5, 4.0 }, spread = 2.0 },
    },
    [2] = {
        handgun = { shots = 5, gap = { 0.5, 0.75 }, pause = { 1.5, 2.5 }, spread = 1.0 },
        auto = { shots = 3, gap = { 0.1, 0.1 }, pause = { 0.75, 1.25 }, spread = 1.0 },
        manual = { shots = 2, gap = { 0.5, 0.75 }, pause = { 1.5, 2.5 }, spread = 1.0 },
        bow = { shots = 1, gap = { 0, 0 }, pause = { 2.0, 2.5 }, spread = 1.0 },
        xbow = { shots = 1, gap = { 0, 0 }, pause = { 2.0, 3.5 }, spread = 1.0 },
    },
}
function S.fire(difficulty, cat)
    local d = S.FIRE[math.max(0, math.min(2, math.floor(tonumber(difficulty) or 1)))]
    if cat == "smg" then cat = "auto" end
    if cat == "shotgun" or cat == "rifle" then cat = "manual" end
    return d[cat] or d.manual
end

-- ArmedNPCCombatMovementSettings_NPC_Lvl_1..5, metres: closes in to
-- `approach` from its target, then every `every` seconds picks a new spot
-- `roam` from the target, at most `angle` degrees off its line, moving at
-- most `step`; `jog` is the chance to jog there instead of walking.
S.COMBAT_MOVE = {
    { approach = { 27, 32 }, roam = { 15, 20 }, step = { 13, 15 }, angle = 20, every = { 10, 14 }, jog = 0.20 },
    { approach = { 28, 33 }, roam = { 15, 18 }, step = { 10, 12 }, angle = 30, every = { 8, 12 }, jog = 0.35 },
    { approach = { 26, 28 }, roam = { 16, 21 }, step = { 13, 16 }, angle = 45, every = { 7, 10 }, jog = 0.40 },
    { approach = { 26, 28 }, roam = { 21, 24 }, step = { 10, 13 }, angle = 60, every = { 7, 9 }, jog = 0.50 },
    { approach = { 28, 33 }, roam = { 23, 28 }, step = { 18, 21 }, angle = 60, every = { 6, 9 }, jog = 0.65 },
}
function S.combat_move(level)
    local lv = math.max(1, math.min(5, math.floor(tonumber(level) or 3)))
    return S.COMBAT_MOVE[lv]
end

-- AISenseConfig on BP_NPCGuardController / BP_NPCDrifterController.
S.SIGHT = { radius_m = 70, lose_m = 85, angle = 80, hearing_m = 120 }

-- Weapons (Items/Weapons/Ranged_Weapons): category, MaxRange (m), rate of
-- fire (rounds a minute), calibre. A few take theirs from a parent class
-- that was not exported and are filled in from the same family.
S.WEAPONS = {
    Weapon_M1911 = { "handgun", 400, 300, "45" }, Weapon_M9 = { "handgun", 400, 300, "9" },
    Weapon_HS9 = { "handgun", 400, 300, "9" }, Weapon_Block21 = { "handgun", 400, 300, "45" },
    Weapon_SF19 = { "handgun", 400, 300, "9" }, Weapon_Krueger = { "handgun", 400, 300, "22" },
    Weapon_DEagle_50 = { "handgun", 400, 200, "50ae" }, Weapon_DEagle_50Gold = { "handgun", 400, 200, "50ae" }, Weapon_Deagle_357 = { "handgun", 400, 350, "357" },
    Weapon_Viper_M357 = { "handgun", 400, 200, "357" }, Weapon_PeaceKeeper38 = { "handgun", 400, 300, "38" },
    Weapon_Judge44 = { "handgun", 400, 200, "44" }, Weapon_Serpent357 = { "handgun", 400, 200, "357" },
    Weapon_Improvised_Handgun = { "handgun", 400, 250, "50ae" },
    Weapon_MP5 = { "smg", 400, 800, "9" }, Weapon_MAC10 = { "smg", 200, 1100, "9" },
    Weapon_UMP45 = { "smg", 400, 599, "45" }, Weapon_AS_Val = { "smg", 500, 900, "9x39" },
    Weapon_AKS_74U = { "smg", 400, 650, "545" }, Weapon_TommyGun = { "auto", 1000, 950, "45" },
    Weapon_AK47 = { "auto", 1000, 600, "762x39" }, Weapon_AKM = { "auto", 1000, 600, "762x39" },
    Weapon_AK15 = { "auto", 1000, 700, "762x39" }, Weapon_M16A4 = { "auto", 1000, 800, "556" },
    Weapon_MK18 = { "auto", 1000, 950, "556" }, Weapon_M249 = { "auto", 1000, 950, "556" },
    Weapon_SCAR_L = { "auto", 400, 650, "556" }, Weapon_VHS2 = { "auto", 1000, 800, "556" },
    Weapon_VHS2_Rail = { "auto", 1000, 800, "556" }, ["Weapon_RPK-74"] = { "auto", 1000, 650, "545" },
    Weapon_VSS_VZ = { "smg", 500, 900, "9x39" },
    Weapon_SVD_Dragunov = { "manual", 1000, 500, "762x54" }, Weapon_SCAR_DMR = { "manual", 1000, 400, "308" },
    Weapon_SKS = { "manual", 400, 260, "762x39" }, Weapon_M1_Garand = { "manual", 400, 500, "3006" },
    Weapon_98k_Karabiner = { "manual", 1000, 35, "792" }, Weapon_MosinNagant = { "manual", 1000, 35, "762x54" },
    Weapon_Hunter85_V2 = { "manual", 1000, 35, "22" }, Weapon_CarbonHunter = { "manual", 1000, 35, "3006" },
    Weapon_AWP = { "manual", 1000, 35, "308" }, Weapon_AWM = { "manual", 1000, 35, "338" },
    Weapon_M82A1 = { "manual", 1000, 200, "50bmg" }, Weapon_Improvised_Rifle = { "manual", 400, 30, "9x39" },
    Weapon_M1887 = { "shotgun", 200, 36, "12" }, Weapon_DT11B = { "shotgun", 200, 300, "12" },
    Weapon_590A11 = { "shotgun", 200, 55, "12" }, Weapon_Trench_Gun = { "shotgun", 200, 88, "12" },
    Weapon_SDASS = { "shotgun", 200, 60, "12" },
    Weapon_BlackHawk_Crossbow = { "xbow", 400, 30, "bolt" }, Weapon_Improvised_Crossbow = { "xbow", 400, 30, "bolt_wood" },
    Compound_Bow = { "bow", 100, 0, "arrow_compound" }, Recurve_Bow = { "bow", 100, 0, "arrow" },
    Improvised_Bow = { "bow", 100, 0, "arrow_crude" },
}

-- Damage of one hit, in health points (NPC health 160-240). The calibres'
-- own numbers live in Items/Ammunition, which has not been exported: these
-- are estimates in the same order as the calibres, to be replaced by
-- SCUM's own when that folder is read. A shotgun's buckshot is one hit for
-- all its pellets at close range and less further out.
S.CALIBRE_DAMAGE = {
    ["22"] = 18, ["9"] = 32, ["38"] = 34, ["45"] = 38, ["357"] = 48, ["44"] = 52, ["50ae"] = 60,
    ["9x39"] = 45, ["545"] = 40, ["556"] = 44, ["762x39"] = 50, ["762x54"] = 75, ["792"] = 78,
    ["308"] = 78, ["3006"] = 80, ["338"] = 100, ["50bmg"] = 160, ["12"] = 85,
    bolt = 85, bolt_wood = 60, arrow = 60, arrow_compound = 75, arrow_crude = 45,
}
S.MELEE_DAMAGE = 30

local cache = {}
-- The stats of a weapon by its spawn name; skins and variants (_ES, _Gold,
-- _Premium, the bow draw weights...) are found under their base weapon.
function S.weapon(name)
    if not name then return nil end
    name = tostring(name)
    if cache[name] ~= nil then return cache[name] or nil end
    local n, w = name, nil
    while n and n ~= "" do
        w = S.WEAPONS[n]
        if w then break end
        n = n:match("^(.*)_[^_]+$")
    end
    local out = false
    if w then
        out = { cat = w[1], max_range_m = w[2], rof = w[3], calibre = w[4],
                damage = S.CALIBRE_DAMAGE[w[4]] or 40 }
    end
    cache[name] = out
    return out or nil
end

return S
